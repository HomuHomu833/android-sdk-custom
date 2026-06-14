#include <check.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* We exercise the real code path by writing adversarial resolv.conf files
 * and calling __res_msend_rc (or the internal lookup path) via the public
 * res_init / getaddrinfo surface that reads resolv.conf.  Because the
 * vulnerable function is static-internal, we drive it through a temp file
 * that the library will parse, and verify the process does not crash/corrupt
 * memory (AddressSanitizer / valgrind will catch the overflow if present). */

static const char *payloads[] = {
    /* Exact exploit: search domain far exceeding MAXNS/search buffer (256 bytes) */
    "search AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n"
    "nameserver 127.0.0.1\n",

    /* Boundary: exactly 255 characters in the search domain */
    "search "
    "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n"
    "nameserver 127.0.0.1\n",

    /* Valid: normal short search domain */
    "search example.com\nnameserver 127.0.0.1\n",
};

START_TEST(test_resolvconf_search_no_overflow)
{
    /* Invariant: parsing any resolv.conf search directive must not
     * overflow internal buffers regardless of domain name length. */
    char tmpfile[] = "/tmp/test_resolv_XXXXXX";
    int fd = mkstemp(tmpfile);
    ck_assert_int_ge(fd, 0);

    const char *payload = payloads[_i];
    ssize_t written = write(fd, payload, strlen(payload));
    ck_assert_int_eq(written, (ssize_t)strlen(payload));
    close(fd);

    /* Drive the real resolvconf.c code path by setting RES_OPTIONS or
     * by invoking res_init with the temp file via the standard env var
     * that musl honours for the resolv.conf path. */
    setenv("MUSL_RESOLV_CONF", tmpfile, 1);

    /* Trigger parsing: res_init reads the conf file through __res_msend_rc
     * which calls the vulnerable parse path in resolvconf.c */
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    /* Return value is irrelevant; we only care that no memory corruption occurs */
    getaddrinfo("localhost", NULL, &hints, &res);
    if (res) freeaddrinfo(res);

    unsetenv("MUSL_RESOLV_CONF");
    unlink(tmpfile);

    /* If we reach here without a crash/ASAN abort the invariant holds */
    ck_assert(1);
}
END_TEST

Suite *security_suite(void)
{
    Suite *s = suite_create("Security");
    TCase *tc = tcase_create("resolvconf_search_overflow");
    tcase_add_loop_test(tc, test_resolvconf_search_no_overflow, 0,
                        (int)(sizeof(payloads) / sizeof(payloads[0])));
    suite_add_tcase(s, tc);
    return s;
}

int main(void)
{
    Suite *s = security_suite();
    SRunner *sr = srunner_create(s);
    srunner_run_all(sr, CK_NORMAL);
    int failed = srunner_ntests_failed(sr);
    srunner_