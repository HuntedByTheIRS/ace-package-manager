#include <gpgme.h>
#include <locale.h>
#include <string.h>
#include <stdio.h>

/*
 * C helper for gpgme operations.
 *
 * V's C interop uses voidptr for opaque types, but gpgme_data_t is a
 * pointer-to-struct and &voidptr produces void** which is incompatible
 * with struct gpgme_data** at the C level.  These wrappers handle the
 * proper casting so V callers can use voidptr safely.
 */

/* Create a gpgme_data_t from a memory buffer (V calls through voidptr). */
int gpgme_data_new_from_mem_wrap(void **data, const char *buffer, size_t size, int copy)
{
    return gpgme_data_new_from_mem((gpgme_data_t *)data, buffer, size, copy);
}

/* Run gpgme_op_verify using voidptrs for the data objects. */
int gpgme_op_verify_wrap(void *ctx, void *sig_data, void *signed_text, void *plaintext)
{
    return gpgme_op_verify((gpgme_ctx_t)ctx,
                           (gpgme_data_t)sig_data,
                           (gpgme_data_t)signed_text,
                           (gpgme_data_t)plaintext);
}

/* Extract signature info from a gpgme_verify_result opaque pointer.
 *
 * gpgme_verify_result_t and gpgme_signature_t are already pointer types,
 * so a straight cast from void* is correct.
 *
 * Returns  0 on success (fpr, status, validity populated).
 * Returns -1 if no signatures found.
 * Returns -2 if no fingerprint present.
 */
int gpgme_extract_sig(void *result, char *fpr_out, int fpr_max,
                      int *status_out, int *validity_out,
                      int *summary_out)
{
    if (!result) return -1;

    gpgme_verify_result_t vr = (gpgme_verify_result_t)result;
    if (!vr || !vr->signatures) {
        *status_out = -999;
        *validity_out = -999;
        *summary_out = -1;
        if (fpr_max > 0 && fpr_out) fpr_out[0] = '\0';
        return -1;
    }

    gpgme_signature_t s = vr->signatures;
    *status_out   = (int)s->status;
    *validity_out = (int)s->validity;
    *summary_out  = s->summary;

    if (s->fpr) {
        int i = 0;
        while (s->fpr[i] && i < fpr_max - 1) {
            fpr_out[i] = s->fpr[i];
            i++;
        }
        fpr_out[i] = '\0';
        return 0;
    }
    return -2;
}

/* One-time GPGME library initialisation.
 *
 * Calls gpgme_check_version() (idempotent — safe to call many times),
 * sets C locale via gpgme_set_locale(), verifies the OpenPGP engine
 * is available, and optionally configures the GPG home directory.
 *
 * @param gpgdir   GPG home directory path (NULL or "" for default)
 * @param errbuf   output buffer for error message (256 bytes minimum)
 * @param errbuf_max  size of errbuf
 * @return 0 on success, -1 on error (errbuf contains human‑readable message)
 */
int gpgme_init_wrap(const char *gpgdir, char *errbuf, int errbuf_max)
{
    gpgme_error_t gpg_err;

    /* gpgme_check_version() initialises the library — safe to call many times. */
    if (!gpgme_check_version(NULL)) {
        snprintf(errbuf, (size_t)errbuf_max, "gpgme_check_version returned NULL");
        return -1;
    }

    /* Set locale so GPGME uses the calling process's locale. */
    gpgme_set_locale(NULL, LC_CTYPE, setlocale(LC_CTYPE, NULL));
#ifdef LC_MESSAGES
    gpgme_set_locale(NULL, LC_MESSAGES, setlocale(LC_MESSAGES, NULL));
#endif

    /* Verify the OpenPGP engine is installed. */
    gpg_err = gpgme_engine_check_version(GPGME_PROTOCOL_OpenPGP);
    if (gpg_err != GPG_ERR_NO_ERROR) {
        snprintf(errbuf, (size_t)errbuf_max,
                 "OpenPGP engine not available: %s",
                 gpgme_strerror(gpg_err));
        return -1;
    }

    /* Point GPGME at the desired keyring. */
    if (gpgdir && gpgdir[0] != '\0') {
        gpg_err = gpgme_set_engine_info(GPGME_PROTOCOL_OpenPGP, NULL, gpgdir);
        if (gpg_err != GPG_ERR_NO_ERROR) {
            snprintf(errbuf, (size_t)errbuf_max,
                     "gpgme_set_engine_info failed: %s",
                     gpgme_strerror(gpg_err));
            return -1;
        }
    }

    return 0;
}
