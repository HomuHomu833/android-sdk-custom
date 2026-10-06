/*
 * Asynchronous transfers over a synchronous BSD libusb backend.
 *
 * The NetBSD, OpenBSD and our FreeBSD backends finish every transfer inside
 * submit_transfer() and cannot cancel one. Older adb (platform-tools 35.0.2
 * and earlier) drives libusb asynchronously: it resubmits reads from their
 * callbacks, on the one event thread, and cancels them on close. There a read
 * waiting for an idle device stalls every other device, and the cancel blocks
 * forever on the transfer lock submit holds.
 *
 * patch-source.sh splices this file into each backend twice: after its
 * includes (declarations) and, with SDK_AQ_IMPL defined, at its end. Bulk and
 * interrupt transfers then run in order on one worker thread per (handle,
 * endpoint); submit only queues. A queued transfer is cancelled in place; a
 * running one is interrupted with SIGURG, which breaks the blocking ugen read
 * or write (EINTR) and which the FreeBSD wait loop polls for. Control transfers
 * stay synchronous: they are short and bounded.
 *
 * Before the second splice the backend defines SDK_AQ_SYNC_SUBMIT and
 * SDK_AQ_SYNC_HANDLE to its own submit_transfer/handle_transfer_completion,
 * and SDK_AQ_SYNC_CANCEL to its cancel_transfer if it has one.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#ifndef SDK_AQ_IMPL

#include <pthread.h>
#include <signal.h>
#include <time.h>

static int sdk_aq_submit(struct usbi_transfer *);
static int sdk_aq_cancel(struct usbi_transfer *);
static int sdk_aq_handle_completion(struct usbi_transfer *);
/* Set by the SIGURG handler in the worker it interrupts. */
static __thread volatile sig_atomic_t sdk_aq_interrupted;

#else /* SDK_AQ_IMPL */

struct sdk_aq_item {
	struct usbi_transfer *it;
	struct sdk_aq_item *next;
};

/* One per (handle, endpoint); kept for the process, reused by later handles. */
struct sdk_aq {
	struct libusb_device_handle *handle;
	unsigned char ep;
	struct sdk_aq_item *head, *tail;
	struct usbi_transfer *cur;	/* running on the worker, if any */
	int cancel_cur;			/* cur was cancelled */
	int running;			/* a worker thread owns this queue */
	pthread_t thr;
	struct sdk_aq *next;
};

/* Transfers that end in an error or a cancel, which the backend's own
 * completion handler would report as completed. */
struct sdk_aq_result {
	struct usbi_transfer *it;
	enum libusb_transfer_status status;
	struct sdk_aq_result *next;
};

static pthread_mutex_t sdk_aq_lock = PTHREAD_MUTEX_INITIALIZER;
static struct sdk_aq *sdk_aqs;
static struct sdk_aq_result *sdk_aq_results;
static pthread_once_t sdk_aq_once = PTHREAD_ONCE_INIT;

static void
sdk_aq_on_signal(int sig)
{
	(void)sig;
	sdk_aq_interrupted = 1;
}

static void
sdk_aq_init(void)
{
	struct sigaction sa;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = sdk_aq_on_signal;	/* no SA_RESTART: reads see EINTR */
	sigemptyset(&sa.sa_mask);
	(void)sigaction(SIGURG, &sa, NULL);
}

/* Report it with status. Call with sdk_aq_lock held. */
static void
sdk_aq_finish_locked(struct usbi_transfer *it, enum libusb_transfer_status status)
{
	struct sdk_aq_result *r = malloc(sizeof(*r));

	if (r != NULL) {
		r->it = it;
		r->status = status;
		r->next = sdk_aq_results;
		sdk_aq_results = r;
	}
	usbi_signal_transfer_completion(it);
}

static enum libusb_transfer_status
sdk_aq_status(int err, int cancelled)
{
	if (cancelled)
		return LIBUSB_TRANSFER_CANCELLED;
	switch (err) {
	case LIBUSB_ERROR_TIMEOUT:	return LIBUSB_TRANSFER_TIMED_OUT;
	case LIBUSB_ERROR_NO_DEVICE:	return LIBUSB_TRANSFER_NO_DEVICE;
	case LIBUSB_ERROR_PIPE:		return LIBUSB_TRANSFER_STALL;
	case LIBUSB_ERROR_OVERFLOW:	return LIBUSB_TRANSFER_OVERFLOW;
	case LIBUSB_ERROR_INTERRUPTED:	return LIBUSB_TRANSFER_CANCELLED;
	default:			return LIBUSB_TRANSFER_ERROR;
	}
}

static void *
sdk_aq_worker(void *arg)
{
	struct sdk_aq *q = arg;
	struct sdk_aq_item *item;
	int err, cancelled;

	pthread_mutex_lock(&sdk_aq_lock);
	while ((item = q->head) != NULL) {
		q->head = item->next;
		if (q->head == NULL)
			q->tail = NULL;
		q->cur = item->it;
		q->cancel_cur = 0;
		sdk_aq_interrupted = 0;
		pthread_mutex_unlock(&sdk_aq_lock);

		/* Signals the completion itself when it succeeds. */
		err = SDK_AQ_SYNC_SUBMIT(item->it);

		pthread_mutex_lock(&sdk_aq_lock);
		cancelled = q->cancel_cur;
		q->cur = NULL;
		if (err != 0)
			sdk_aq_finish_locked(item->it, sdk_aq_status(err, cancelled));
		free(item);
	}
	q->running = 0;
	pthread_mutex_unlock(&sdk_aq_lock);
	return NULL;
}

/* Re-sends SIGURG until the cancelled transfer leaves its worker: a signal
 * that lands just before the worker blocks in read() would be lost. */
struct sdk_aq_kick {
	struct sdk_aq *q;
	struct usbi_transfer *it;
};

static void *
sdk_aq_kicker(void *arg)
{
	struct sdk_aq_kick *k = arg;
	struct timespec ts = { 0, 100 * 1000 * 1000 };
	int i;

	for (i = 0; i < 600; i++) {	/* a minute at most */
		nanosleep(&ts, NULL);
		pthread_mutex_lock(&sdk_aq_lock);
		if (k->q->cur != k->it || !k->q->cancel_cur) {
			pthread_mutex_unlock(&sdk_aq_lock);
			break;
		}
		(void)pthread_kill(k->q->thr, SIGURG);
		pthread_mutex_unlock(&sdk_aq_lock);
	}
	free(k);
	return NULL;
}

static int
sdk_aq_submit(struct usbi_transfer *it)
{
	struct libusb_transfer *transfer = USBI_TRANSFER_TO_LIBUSB_TRANSFER(it);
	struct sdk_aq *q;
	struct sdk_aq_item *item;
	pthread_attr_t attr;
	int rc;

	if (transfer->type != LIBUSB_TRANSFER_TYPE_BULK &&
	    transfer->type != LIBUSB_TRANSFER_TYPE_INTERRUPT)
		return SDK_AQ_SYNC_SUBMIT(it);

	pthread_once(&sdk_aq_once, sdk_aq_init);
	item = malloc(sizeof(*item));
	if (item == NULL)
		return LIBUSB_ERROR_NO_MEM;
	item->it = it;
	item->next = NULL;

	pthread_mutex_lock(&sdk_aq_lock);
	for (q = sdk_aqs; q != NULL; q = q->next)
		if (q->handle == transfer->dev_handle && q->ep == transfer->endpoint)
			break;
	if (q == NULL) {
		q = calloc(1, sizeof(*q));
		if (q == NULL) {
			pthread_mutex_unlock(&sdk_aq_lock);
			free(item);
			return LIBUSB_ERROR_NO_MEM;
		}
		q->handle = transfer->dev_handle;
		q->ep = transfer->endpoint;
		q->next = sdk_aqs;
		sdk_aqs = q;
	}
	if (q->tail != NULL)
		q->tail->next = item;
	else
		q->head = item;
	q->tail = item;

	if (!q->running) {
		pthread_attr_init(&attr);
		pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
		rc = pthread_create(&q->thr, &attr, sdk_aq_worker, q);
		pthread_attr_destroy(&attr);
		if (rc != 0) {
			/* item is the only one queued: no worker means an empty queue. */
			q->head = q->tail = NULL;
			pthread_mutex_unlock(&sdk_aq_lock);
			free(item);
			return LIBUSB_ERROR_NO_MEM;
		}
		q->running = 1;
	}
	pthread_mutex_unlock(&sdk_aq_lock);
	return LIBUSB_SUCCESS;
}

static int
sdk_aq_cancel(struct usbi_transfer *it)
{
	struct sdk_aq *q;
	struct sdk_aq_item **pp, *item;
	struct sdk_aq_kick *k;
	pthread_attr_t attr;
	pthread_t kt;

	pthread_mutex_lock(&sdk_aq_lock);
	for (q = sdk_aqs; q != NULL; q = q->next) {
		for (pp = &q->head; (item = *pp) != NULL; pp = &item->next) {
			if (item->it != it)
				continue;
			*pp = item->next;
			if (q->tail == item) {
				struct sdk_aq_item *t = q->head;
				while (t != NULL && t->next != NULL)
					t = t->next;
				q->tail = t;
			}
			free(item);
			sdk_aq_finish_locked(it, LIBUSB_TRANSFER_CANCELLED);
			pthread_mutex_unlock(&sdk_aq_lock);
			return LIBUSB_SUCCESS;
		}
		if (q->cur == it) {
			if (!q->cancel_cur) {
				q->cancel_cur = 1;
				(void)pthread_kill(q->thr, SIGURG);
				k = malloc(sizeof(*k));
				if (k != NULL) {
					k->q = q;
					k->it = it;
					pthread_attr_init(&attr);
					pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
					if (pthread_create(&kt, &attr, sdk_aq_kicker, k) != 0)
						free(k);
					pthread_attr_destroy(&attr);
				}
			}
			pthread_mutex_unlock(&sdk_aq_lock);
			return LIBUSB_SUCCESS;
		}
	}
	pthread_mutex_unlock(&sdk_aq_lock);
#if defined(SDK_AQ_SYNC_CANCEL)
	return SDK_AQ_SYNC_CANCEL(it);
#else
	return LIBUSB_ERROR_NOT_FOUND;
#endif
}

static int
sdk_aq_handle_completion(struct usbi_transfer *it)
{
	struct sdk_aq_result **pp, *r;
	enum libusb_transfer_status status;

	pthread_mutex_lock(&sdk_aq_lock);
	for (pp = &sdk_aq_results; (r = *pp) != NULL; pp = &r->next) {
		if (r->it != it)
			continue;
		*pp = r->next;
		status = r->status;
		free(r);
		pthread_mutex_unlock(&sdk_aq_lock);
		if (status == LIBUSB_TRANSFER_CANCELLED)
			return usbi_handle_transfer_cancellation(it);
		return usbi_handle_transfer_completion(it, status);
	}
	pthread_mutex_unlock(&sdk_aq_lock);
	return SDK_AQ_SYNC_HANDLE(it);
}

#endif /* SDK_AQ_IMPL */
