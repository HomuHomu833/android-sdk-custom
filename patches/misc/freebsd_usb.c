/*
 * FreeBSD backend for libusb 1.0
 *
 * Upstream libusb has no FreeBSD backend (configure.ac has no *-freebsd* case),
 * so cross-builds fell back to os/null_usb.c, which enumerates zero devices and
 * makes fastboot never see anything. This backend talks to FreeBSD's ugen(4)
 * driver directly:
 *
 *   - one character node per device: /dev/ugen<bus>.<addr>
 *   - descriptors / control transfers via the USB_* ioctls
 *   - bulk/interrupt transfers via the USB_FS_* ioctl interface (zero-copy over
 *     ordinary userland buffers; no mmap), modelled on FreeBSD's own libusb20
 *     ugen20 backend.
 *
 * It is synchronous (transfers complete inside submit_transfer, like the
 * OpenBSD/NetBSD backends), which is all fastboot/adb host tooling needs.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#include <config.h>

#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/time.h>

#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <dev/usb/usb.h>
#include <dev/usb/usbdi.h>
#include <dev/usb/usb_ioctl.h>

#include "libusbi.h"

#define DEVPATH		"/dev/"
#define UGEN_FMT	DEVPATH "ugen%u.%u"

/* Number of concurrently-open USB-FS endpoint slots per handle. fastboot/adb use
 * one bulk-IN and one bulk-OUT; four leaves headroom. */
#define FBSD_NFSEP	4

struct device_priv {
	char		devnode[32];	/* /dev/ugen<bus>.<addr> */
	unsigned char  *cdesc;		/* cached active config descriptor blob */
	int		cdesc_len;
	uint8_t		cval;		/* active bConfigurationValue */
};

struct handle_priv {
	int		fd;		/* O_RDWR node fd; also USB_FS_* target */
	int		fs_inited;	/* USB_FS_INIT has run */
	struct usb_fs_endpoint fsep[FBSD_NFSEP];
	void	       *ppbuf[FBSD_NFSEP];	/* single-frame buffer pointer */
	uint32_t	plen[FBSD_NFSEP];	/* single-frame length */
	uint8_t		ep_no[FBSD_NFSEP];	/* bound bEndpointAddress, 0=free */
	uint32_t	ep_bufsize[FBSD_NFSEP];	/* current opened max_bufsize */
};

static int fbsd_get_device_list(struct libusb_context *,
    struct discovered_devs **);
static int fbsd_open(struct libusb_device_handle *);
static void fbsd_close(struct libusb_device_handle *);
static int fbsd_get_active_config_descriptor(struct libusb_device *,
    void *, size_t);
static int fbsd_get_config_descriptor(struct libusb_device *, uint8_t,
    void *, size_t);
static int fbsd_get_configuration(struct libusb_device_handle *, uint8_t *);
static int fbsd_set_configuration(struct libusb_device_handle *, int);
static int fbsd_claim_interface(struct libusb_device_handle *, uint8_t);
static int fbsd_release_interface(struct libusb_device_handle *, uint8_t);
static int fbsd_set_interface_altsetting(struct libusb_device_handle *, uint8_t,
    uint8_t);
static int fbsd_clear_halt(struct libusb_device_handle *, unsigned char);
static void fbsd_destroy_device(struct libusb_device *);
static int fbsd_submit_transfer(struct usbi_transfer *);
static int fbsd_cancel_transfer(struct usbi_transfer *);
static int fbsd_handle_transfer_completion(struct usbi_transfer *);

static int _errno_to_libusb(int);
static int _open_node(struct libusb_device *, int mode);
static int _cache_active_config_descriptor(struct libusb_device *, int fd);
static int _sync_control_transfer(struct usbi_transfer *);
static int _sync_gen_transfer(struct usbi_transfer *);

const struct usbi_os_backend usbi_backend = {
	.name = "Synchronous FreeBSD backend",
	.caps = 0,
	.get_device_list = fbsd_get_device_list,
	.open = fbsd_open,
	.close = fbsd_close,
	.get_active_config_descriptor = fbsd_get_active_config_descriptor,
	.get_config_descriptor = fbsd_get_config_descriptor,
	.get_configuration = fbsd_get_configuration,
	.set_configuration = fbsd_set_configuration,
	.claim_interface = fbsd_claim_interface,
	.release_interface = fbsd_release_interface,
	.set_interface_altsetting = fbsd_set_interface_altsetting,
	.clear_halt = fbsd_clear_halt,
	.destroy_device = fbsd_destroy_device,
	.submit_transfer = fbsd_submit_transfer,
	.cancel_transfer = fbsd_cancel_transfer,
	.handle_transfer_completion = fbsd_handle_transfer_completion,
	.device_priv_size = sizeof(struct device_priv),
	.device_handle_priv_size = sizeof(struct handle_priv),
};

static enum libusb_speed
_fbsd_speed(uint8_t udi_speed)
{
	switch (udi_speed) {
	case USB_SPEED_LOW:	return LIBUSB_SPEED_LOW;
	case USB_SPEED_FULL:	return LIBUSB_SPEED_FULL;
	case USB_SPEED_HIGH:	return LIBUSB_SPEED_HIGH;
	case USB_SPEED_SUPER:	return LIBUSB_SPEED_SUPER;
	default:		return LIBUSB_SPEED_UNKNOWN;
	}
}

int
fbsd_get_device_list(struct libusb_context *ctx,
    struct discovered_devs **discdevs)
{
	struct discovered_devs *ddd;
	struct libusb_device *dev;
	struct device_priv *dpriv;
	struct usb_device_info di;
	struct usb_device_descriptor ddesc;
	DIR *dir;
	struct dirent *de;
	unsigned int bus, addr;
	char extra;
	char node[32];
	int fd;

	usbi_dbg(ctx, " ");

	if ((dir = opendir(DEVPATH)) == NULL)
		return _errno_to_libusb(errno);

	while ((de = readdir(dir)) != NULL) {
		/* Match exactly "ugen<bus>.<addr>" (no trailing endpoint node). */
		if (sscanf(de->d_name, "ugen%u.%u%c", &bus, &addr, &extra) != 2)
			continue;

		snprintf(node, sizeof(node), DEVPATH "%s", de->d_name);
		if ((fd = open(node, O_RDONLY)) < 0)
			continue;

		if (ioctl(fd, USB_GET_DEVICEINFO, &di) < 0) {
			close(fd);
			continue;
		}

		unsigned long session_id =
		    ((unsigned long)di.udi_bus << 8) | di.udi_addr;
		dev = usbi_get_device_by_session_id(ctx, session_id);
		if (dev == NULL) {
			dev = usbi_alloc_device(ctx, session_id);
			if (dev == NULL) {
				close(fd);
				closedir(dir);
				return LIBUSB_ERROR_NO_MEM;
			}

			dev->bus_number = di.udi_bus;
			dev->device_address = di.udi_addr;
			dev->speed = _fbsd_speed(di.udi_speed);

			dpriv = usbi_get_device_priv(dev);
			memset(dpriv, 0, sizeof(*dpriv));
			snprintf(dpriv->devnode, sizeof(dpriv->devnode),
			    UGEN_FMT, bus, addr);

			if (ioctl(fd, USB_GET_DEVICE_DESC, &ddesc) < 0) {
				libusb_unref_device(dev);
				close(fd);
				continue;
			}
			static_assert(sizeof(dev->device_descriptor) ==
			    LIBUSB_DT_DEVICE_SIZE, "device descriptor size");
			memcpy(&dev->device_descriptor, &ddesc,
			    LIBUSB_DT_DEVICE_SIZE);
			usbi_localize_device_descriptor(&dev->device_descriptor);

			if (_cache_active_config_descriptor(dev, fd)) {
				libusb_unref_device(dev);
				close(fd);
				continue;
			}
			if (usbi_sanitize_device(dev)) {
				libusb_unref_device(dev);
				close(fd);
				continue;
			}
		}
		close(fd);

		ddd = discovered_devs_append(*discdevs, dev);
		if (ddd == NULL) {
			libusb_unref_device(dev);
			closedir(dir);
			return LIBUSB_ERROR_NO_MEM;
		}
		libusb_unref_device(dev);
		*discdevs = ddd;
	}

	closedir(dir);
	return LIBUSB_SUCCESS;
}

int
fbsd_open(struct libusb_device_handle *handle)
{
	struct device_priv *dpriv = usbi_get_device_priv(handle->dev);
	struct handle_priv *hpriv = usbi_get_device_handle_priv(handle);
	struct usb_fs_init fsinit;
	int i;

	memset(hpriv, 0, sizeof(*hpriv));

	hpriv->fd = open(dpriv->devnode, O_RDWR);
	if (hpriv->fd < 0)
		return _errno_to_libusb(errno);

	for (i = 0; i < FBSD_NFSEP; i++)
		hpriv->ep_no[i] = 0;

	memset(&fsinit, 0, sizeof(fsinit));
	fsinit.pEndpoints = hpriv->fsep;
	fsinit.ep_index_max = FBSD_NFSEP;
	if (ioctl(hpriv->fd, USB_FS_INIT, &fsinit) == 0)
		hpriv->fs_inited = 1;
	/* If USB_FS_INIT fails, control transfers still work; bulk will error. */

	usbi_dbg(HANDLE_CTX(handle), "open %s: fd %d", dpriv->devnode, hpriv->fd);
	return LIBUSB_SUCCESS;
}

void
fbsd_close(struct libusb_device_handle *handle)
{
	struct handle_priv *hpriv = usbi_get_device_handle_priv(handle);
	struct usb_fs_close fsclose;
	struct usb_fs_uninit fsuninit;
	int i;

	if (hpriv->fs_inited) {
		for (i = 0; i < FBSD_NFSEP; i++) {
			if (hpriv->ep_no[i] == 0)
				continue;
			memset(&fsclose, 0, sizeof(fsclose));
			fsclose.ep_index = i;
			(void)ioctl(hpriv->fd, USB_FS_CLOSE, &fsclose);
		}
		memset(&fsuninit, 0, sizeof(fsuninit));
		(void)ioctl(hpriv->fd, USB_FS_UNINIT, &fsuninit);
	}
	if (hpriv->fd >= 0)
		close(hpriv->fd);
	hpriv->fd = -1;
}

int
fbsd_get_active_config_descriptor(struct libusb_device *dev,
    void *buf, size_t len)
{
	struct device_priv *dpriv = usbi_get_device_priv(dev);

	if (dpriv->cdesc == NULL)
		return LIBUSB_ERROR_NOT_FOUND;

	len = MIN(len, (size_t)dpriv->cdesc_len);
	memcpy(buf, dpriv->cdesc, len);
	return (int)len;
}

int
fbsd_get_config_descriptor(struct libusb_device *dev, uint8_t idx,
    void *buf, size_t len)
{
	struct usb_gen_descriptor ugd;
	int fd, err;

	if ((fd = _open_node(dev, O_RDONLY)) < 0)
		return _errno_to_libusb(errno);

	memset(&ugd, 0, sizeof(ugd));
	ugd.ugd_data = buf;
	ugd.ugd_maxlen = (uint16_t)MIN(len, 0xffffU);
	ugd.ugd_config_index = idx;

	if (ioctl(fd, USB_GET_FULL_DESC, &ugd) < 0) {
		err = errno;
		close(fd);
		return _errno_to_libusb(err);
	}
	close(fd);
	return ugd.ugd_actlen;
}

int
fbsd_get_configuration(struct libusb_device_handle *handle, uint8_t *config)
{
	struct handle_priv *hpriv = usbi_get_device_handle_priv(handle);
	int val;

	if (ioctl(hpriv->fd, USB_GET_CONFIG, &val) < 0)
		return _errno_to_libusb(errno);
	*config = (uint8_t)val;
	return LIBUSB_SUCCESS;
}

int
fbsd_set_configuration(struct libusb_device_handle *handle, int config)
{
	struct handle_priv *hpriv = usbi_get_device_handle_priv(handle);
	int fd, err;

	if (ioctl(hpriv->fd, USB_SET_CONFIG, &config) < 0)
		return _errno_to_libusb(errno);

	/* Refresh the cached active config descriptor. */
	if ((fd = _open_node(handle->dev, O_RDONLY)) >= 0) {
		err = _cache_active_config_descriptor(handle->dev, fd);
		close(fd);
		return err;
	}
	return LIBUSB_SUCCESS;
}

int
fbsd_claim_interface(struct libusb_device_handle *handle, uint8_t iface)
{
	UNUSED(handle);
	UNUSED(iface);
	/* ugen(4) grants the whole device to the opener; nothing to claim. */
	return LIBUSB_SUCCESS;
}

int
fbsd_release_interface(struct libusb_device_handle *handle, uint8_t iface)
{
	UNUSED(handle);
	UNUSED(iface);
	return LIBUSB_SUCCESS;
}

int
fbsd_set_interface_altsetting(struct libusb_device_handle *handle, uint8_t iface,
    uint8_t altsetting)
{
	struct handle_priv *hpriv = usbi_get_device_handle_priv(handle);
	struct usb_alt_interface intf;

	memset(&intf, 0, sizeof(intf));
	intf.uai_interface_index = iface;
	intf.uai_alt_index = altsetting;

	if (ioctl(hpriv->fd, USB_SET_ALTINTERFACE, &intf) < 0)
		return _errno_to_libusb(errno);
	return LIBUSB_SUCCESS;
}

int
fbsd_clear_halt(struct libusb_device_handle *handle, unsigned char endpoint)
{
	struct handle_priv *hpriv = usbi_get_device_handle_priv(handle);
	struct usb_ctl_request req;
	uint16_t v, i, l;

	memset(&req, 0, sizeof(req));
	req.ucr_request.bmRequestType = UT_WRITE_ENDPOINT;
	req.ucr_request.bRequest = UR_CLEAR_FEATURE;
	v = UF_ENDPOINT_HALT; i = endpoint; l = 0;
	memcpy(req.ucr_request.wValue, &v, 2);
	memcpy(req.ucr_request.wIndex, &i, 2);
	memcpy(req.ucr_request.wLength, &l, 2);

	if (ioctl(hpriv->fd, USB_DO_REQUEST, &req) < 0)
		return _errno_to_libusb(errno);
	return LIBUSB_SUCCESS;
}

void
fbsd_destroy_device(struct libusb_device *dev)
{
	struct device_priv *dpriv = usbi_get_device_priv(dev);

	free(dpriv->cdesc);
	dpriv->cdesc = NULL;
}

int
fbsd_submit_transfer(struct usbi_transfer *itransfer)
{
	struct libusb_transfer *transfer =
	    USBI_TRANSFER_TO_LIBUSB_TRANSFER(itransfer);
	int err;

	switch (transfer->type) {
	case LIBUSB_TRANSFER_TYPE_CONTROL:
		err = _sync_control_transfer(itransfer);
		break;
	case LIBUSB_TRANSFER_TYPE_BULK:
	case LIBUSB_TRANSFER_TYPE_INTERRUPT:
		err = _sync_gen_transfer(itransfer);
		break;
	case LIBUSB_TRANSFER_TYPE_ISOCHRONOUS:
	case LIBUSB_TRANSFER_TYPE_BULK_STREAM:
	default:
		err = LIBUSB_ERROR_NOT_SUPPORTED;
		break;
	}

	if (err)
		return err;

	usbi_signal_transfer_completion(itransfer);
	return LIBUSB_SUCCESS;
}

int
fbsd_cancel_transfer(struct usbi_transfer *itransfer)
{
	UNUSED(itransfer);
	/* Synchronous backend: transfers finish inside submit, nothing to cancel. */
	return LIBUSB_ERROR_NOT_SUPPORTED;
}

int
fbsd_handle_transfer_completion(struct usbi_transfer *itransfer)
{
	return usbi_handle_transfer_completion(itransfer,
	    LIBUSB_TRANSFER_COMPLETED);
}

int
_errno_to_libusb(int err)
{
	switch (err) {
	case EIO:	return LIBUSB_ERROR_IO;
	case EACCES:	return LIBUSB_ERROR_ACCESS;
	case ENOENT:
	case ENXIO:	return LIBUSB_ERROR_NO_DEVICE;
	case ENOMEM:	return LIBUSB_ERROR_NO_MEM;
	case ETIMEDOUT:	return LIBUSB_ERROR_TIMEOUT;
	case EBUSY:	return LIBUSB_ERROR_BUSY;
	default:	return LIBUSB_ERROR_OTHER;
	}
}

int
_open_node(struct libusb_device *dev, int mode)
{
	struct device_priv *dpriv = usbi_get_device_priv(dev);

	return open(dpriv->devnode, mode);
}

int
_cache_active_config_descriptor(struct libusb_device *dev, int fd)
{
	struct device_priv *dpriv = usbi_get_device_priv(dev);
	struct usb_device_info di;
	struct usb_gen_descriptor ugd;
	unsigned char hdr[8];
	unsigned char *buf;
	int total;

	if (ioctl(fd, USB_GET_DEVICEINFO, &di) < 0)
		return _errno_to_libusb(errno);
	dpriv->cval = di.udi_config_no;

	/* First read just the config descriptor header to learn wTotalLength. */
	memset(&ugd, 0, sizeof(ugd));
	ugd.ugd_data = hdr;
	ugd.ugd_maxlen = sizeof(hdr);
	ugd.ugd_config_index = di.udi_config_index;
	if (ioctl(fd, USB_GET_FULL_DESC, &ugd) < 0)
		return _errno_to_libusb(errno);
	if (ugd.ugd_actlen < 4)
		return LIBUSB_ERROR_IO;

	total = hdr[2] | (hdr[3] << 8);		/* wTotalLength, little-endian */
	if (total < 4)
		return LIBUSB_ERROR_IO;

	buf = malloc((size_t)total);
	if (buf == NULL)
		return LIBUSB_ERROR_NO_MEM;

	memset(&ugd, 0, sizeof(ugd));
	ugd.ugd_data = buf;
	ugd.ugd_maxlen = (uint16_t)total;
	ugd.ugd_config_index = di.udi_config_index;
	if (ioctl(fd, USB_GET_FULL_DESC, &ugd) < 0) {
		free(buf);
		return _errno_to_libusb(errno);
	}

	free(dpriv->cdesc);
	dpriv->cdesc = buf;
	dpriv->cdesc_len = ugd.ugd_actlen;
	return LIBUSB_SUCCESS;
}

int
_sync_control_transfer(struct usbi_transfer *itransfer)
{
	struct libusb_transfer *transfer =
	    USBI_TRANSFER_TO_LIBUSB_TRANSFER(itransfer);
	struct handle_priv *hpriv =
	    usbi_get_device_handle_priv(transfer->dev_handle);
	struct libusb_control_setup *setup =
	    (struct libusb_control_setup *)transfer->buffer;
	struct usb_ctl_request req;

	memset(&req, 0, sizeof(req));
	req.ucr_request.bmRequestType = setup->bmRequestType;
	req.ucr_request.bRequest = setup->bRequest;
	/* setup->wValue/wIndex/wLength are already little-endian in the buffer. */
	memcpy(req.ucr_request.wValue, &setup->wValue, 2);
	memcpy(req.ucr_request.wIndex, &setup->wIndex, 2);
	memcpy(req.ucr_request.wLength, &setup->wLength, 2);
	req.ucr_data = transfer->buffer + LIBUSB_CONTROL_SETUP_SIZE;
	if ((transfer->flags & LIBUSB_TRANSFER_SHORT_NOT_OK) == 0)
		req.ucr_flags = USB_SHORT_XFER_OK;

	if (ioctl(hpriv->fd, USB_DO_REQUEST, &req) < 0)
		return _errno_to_libusb(errno);

	itransfer->transferred = req.ucr_actlen;
	return 0;
}

/* Find an open FS slot for ep, or allocate/(re)open one big enough. */
static int
_fs_slot(struct handle_priv *hpriv, uint8_t ep, uint32_t need)
{
	struct usb_fs_open fsopen;
	struct usb_fs_close fsclose;
	int i, slot = -1, free_slot = -1;

	for (i = 0; i < FBSD_NFSEP; i++) {
		if (hpriv->ep_no[i] == ep) { slot = i; break; }
		if (hpriv->ep_no[i] == 0 && free_slot < 0) free_slot = i;
	}

	if (slot >= 0 && hpriv->ep_bufsize[slot] >= need)
		return slot;

	if (slot < 0)
		slot = free_slot;
	if (slot < 0)
		return LIBUSB_ERROR_NO_MEM;	/* out of FS slots */

	if (hpriv->ep_no[slot] != 0) {		/* reopen larger */
		memset(&fsclose, 0, sizeof(fsclose));
		fsclose.ep_index = slot;
		(void)ioctl(hpriv->fd, USB_FS_CLOSE, &fsclose);
		hpriv->ep_no[slot] = 0;
	}

	if (need == 0)
		need = 1;
	if (need > USB_FS_MAX_BUFSIZE)
		need = USB_FS_MAX_BUFSIZE;

	memset(&fsopen, 0, sizeof(fsopen));
	fsopen.ep_index = slot;
	fsopen.ep_no = ep;
	fsopen.max_bufsize = need;
	fsopen.max_frames = 1;
	if (ioctl(hpriv->fd, USB_FS_OPEN, &fsopen) < 0)
		return _errno_to_libusb(errno);

	hpriv->ep_no[slot] = ep;
	hpriv->ep_bufsize[slot] = fsopen.max_bufsize;
	return slot;
}

int
_sync_gen_transfer(struct usbi_transfer *itransfer)
{
	struct libusb_transfer *transfer =
	    USBI_TRANSFER_TO_LIBUSB_TRANSFER(itransfer);
	struct handle_priv *hpriv =
	    usbi_get_device_handle_priv(transfer->dev_handle);
	struct usb_fs_endpoint *fsep;
	struct usb_fs_start fsstart;
	struct usb_fs_complete fscomp;
	struct pollfd pfd;
	int slot;

	if (!hpriv->fs_inited)
		return LIBUSB_ERROR_NOT_SUPPORTED;

	slot = _fs_slot(hpriv, (uint8_t)transfer->endpoint,
	    (uint32_t)transfer->length);
	if (slot < 0)
		return slot;

	hpriv->ppbuf[slot] = transfer->buffer;
	hpriv->plen[slot] = (uint32_t)transfer->length;

	fsep = &hpriv->fsep[slot];
	memset(fsep, 0, sizeof(*fsep));
	fsep->ppBuffer = &hpriv->ppbuf[slot];
	fsep->pLength = &hpriv->plen[slot];
	fsep->nFrames = 1;
	fsep->timeout = (uint16_t)MIN(transfer->timeout, 0xffff);
	if (IS_XFERIN(transfer) &&
	    (transfer->flags & LIBUSB_TRANSFER_SHORT_NOT_OK) == 0)
		fsep->flags = USB_FS_FLAG_SINGLE_SHORT_OK;

	memset(&fsstart, 0, sizeof(fsstart));
	fsstart.ep_index = slot;
	if (ioctl(hpriv->fd, USB_FS_START, &fsstart) < 0)
		return _errno_to_libusb(errno);

	for (;;) {
		pfd.fd = hpriv->fd;
		pfd.events = POLLIN | POLLOUT | POLLRDNORM | POLLWRNORM;
		pfd.revents = 0;
		if (poll(&pfd, 1, transfer->timeout > 0 ? transfer->timeout : -1)
		    == 0)
			return LIBUSB_ERROR_TIMEOUT;

		memset(&fscomp, 0, sizeof(fscomp));
		if (ioctl(hpriv->fd, USB_FS_COMPLETE, &fscomp) < 0) {
			if (errno == EBUSY)
				continue;	/* not finished yet */
			return _errno_to_libusb(errno);
		}
		if (fscomp.ep_index == slot)
			break;
		/* completion for another endpoint; keep draining */
	}

	if (fsep->status != 0)
		return LIBUSB_ERROR_IO;

	/* pLength[0] was updated to the actual transferred length. */
	itransfer->transferred = (int)hpriv->plen[slot];
	return 0;
}
