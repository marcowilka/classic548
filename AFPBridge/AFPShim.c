#include "AFPShim.h"

#include <errno.h>
#include <netatalk-client/afpsl.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

/*
 * libafpsl mostly returns negative errno values, but daemon_connect() still
 * returns a bare -1 with errno set. On Darwin EPERM==1 so -EPERM==-1 — Swift
 * must never see an unresolved -1.
 */
static int shim_normalize_rc(int rc)
{
    if (rc == 0) {
        return 0;
    }
    if (rc == -1) {
        int saved = errno;
        if (saved > 0) {
            return -saved;
        }
        return -EIO;
    }
    return rc;
}

static void fill_url(struct afpc_url *dst, const AFPShimURL *src)
{
    afp_sl_url_init(dst);
    dst->protocol = AFPC_TRANSPORT_TCPIP;
    dst->port = src->port > 0 ? src->port : 548;
    strncpy(dst->username, src->username, sizeof(dst->username) - 1);
    strncpy(dst->password, src->password, sizeof(dst->password) - 1);
    strncpy(dst->servername, src->servername, sizeof(dst->servername) - 1);
    strncpy(dst->volumename, src->volumename, sizeof(dst->volumename) - 1);
    afp_sl_url_set_path(dst, src->path[0] ? src->path : "/");
}

unsigned int afp_shim_default_uams(void)
{
    /* Prefer encrypted UAMs used by Synology/Netatalk NAS gear.
     * pick_uam() chooses the highest bit; keep SRP out so DHX2 wins on
     * servers that only advertise DHX2/DHCAST128. */
    unsigned int mask = afp_sl_default_uams();
    mask &= (unsigned int)(AFP_SL_UAM_DHX2 | AFP_SL_UAM_DHCAST128 |
                           AFP_SL_UAM_CLEARTEXT | AFP_SL_UAM_RANDNUM |
                           AFP_SL_UAM_TWO_WAY_RANDNUM);
    return mask ? mask : afp_sl_default_uams();
}

unsigned int afp_shim_guest_uams(void)
{
    return (unsigned int)AFP_SL_UAM_NO_USER_AUTH;
}

int afp_shim_exit(void)
{
    return shim_normalize_rc(afp_sl_exit());
}

int afp_shim_connect(const AFPShimURL *url, unsigned int uam_mask, AFPServerHandle *out_server)
{
    struct afpc_url parsed;
    afpc_server_t server = NULL;
    char message[256];
    int rc;

    if (!url || !out_server) {
        return -EINVAL;
    }
    fill_url(&parsed, url);
    memset(message, 0, sizeof(message));
    rc = afp_sl_connect(&parsed, uam_mask ? uam_mask : afp_sl_default_uams(), &server, message);
    afp_sl_url_clear(&parsed);
    rc = shim_normalize_rc(rc);
    if (rc == 0) {
        *out_server = server;
    }
    return rc;
}

int afp_shim_resume(const AFPShimURL *url, unsigned int uam_mask, AFPServerHandle *out_server)
{
    struct afpc_url parsed;
    afpc_server_t server = NULL;
    char message[256];
    int rc;

    if (!url || !out_server) {
        return -EINVAL;
    }
    fill_url(&parsed, url);
    /* Resume must be password-less — afpsld returns EACCES if one is present. */
    memset(parsed.password, 0, sizeof(parsed.password));
    memset(message, 0, sizeof(message));
    rc = afp_sl_resume(&parsed, uam_mask ? uam_mask : afp_sl_default_uams(), &server, message);
    afp_sl_url_clear(&parsed);
    rc = shim_normalize_rc(rc);
    if (rc == 0) {
        *out_server = server;
    }
    return rc;
}

int afp_shim_disconnect(AFPServerHandle *server)
{
    afpc_server_t handle;

    if (!server || !*server) {
        return 0;
    }
    handle = *server;
    *server = NULL;
    return shim_normalize_rc(afp_sl_disconnect(&handle));
}

int afp_shim_attach(AFPServerHandle server, const AFPShimURL *url, AFPVolumeHandle *out_volume, int *needs_vol_password)
{
    struct afpc_url parsed;
    afpc_volume_t volume = NULL;
    enum afp_sl_attach_status status = AFP_SL_ATTACH_STATUS_NONE;
    int rc;

    if (!server || !url || !out_volume) {
        return -EINVAL;
    }
    fill_url(&parsed, url);
    rc = afp_sl_attach((afpc_server_t)server, &parsed, 0, &volume, &status);
    afp_sl_url_clear(&parsed);
    rc = shim_normalize_rc(rc);
    if (needs_vol_password) {
        *needs_vol_password = (status == AFP_SL_ATTACH_STATUS_PASSWORD_REQUIRED);
    }
    if (rc == 0) {
        *out_volume = volume;
    }
    return rc;
}

int afp_shim_detach(AFPVolumeHandle *volume, const AFPShimURL *url)
{
    struct afpc_url parsed;
    afpc_volume_t handle;
    int rc;

    if (!volume || !*volume) {
        return 0;
    }
    handle = *volume;
    *volume = NULL;
    fill_url(&parsed, url ? url : &(AFPShimURL){0});
    rc = afp_sl_detach(&handle, &parsed);
    afp_sl_url_clear(&parsed);
    return shim_normalize_rc(rc);
}

int afp_shim_list_volumes(AFPServerHandle server, const AFPShimURL *url, char *out_names, size_t out_size, unsigned int *out_count)
{
    struct afpc_url parsed;
    struct afpc_volume_info vols[64];
    unsigned int count = 0;
    size_t offset = 0;
    unsigned int i;
    int rc;

    if (!server || !url || !out_names || !out_count || out_size == 0) {
        return -EINVAL;
    }
    fill_url(&parsed, url);
    memset(vols, 0, sizeof(vols));
    rc = shim_normalize_rc(afp_sl_getvols((afpc_server_t)server, &parsed, 0, 64, &count, vols));
    afp_sl_url_clear(&parsed);
    if (rc != 0) {
        return rc;
    }
    out_names[0] = '\0';
    for (i = 0; i < count; i++) {
        size_t len = strlen(vols[i].volume_name_printable);
        if (offset + len + 2 > out_size) {
            break;
        }
        memcpy(out_names + offset, vols[i].volume_name_printable, len);
        offset += len;
        out_names[offset++] = '\0';
    }
    if (offset < out_size) {
        out_names[offset] = '\0';
    }
    *out_count = i;
    return 0;
}

int afp_shim_stat(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, struct stat *out_stat)
{
    struct afpc_url parsed;
    int rc;

    if (!volume || !*volume || !path || !out_stat) {
        return -EINVAL;
    }
    fill_url(&parsed, url ? url : &(AFPShimURL){0});
    rc = afp_sl_stat((afpc_volume_t *)volume, path, &parsed, out_stat);
    afp_sl_url_clear(&parsed);
    return shim_normalize_rc(rc);
}

int afp_shim_statfs(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, struct statvfs *out_stat)
{
    struct afpc_url parsed;
    int rc;

    if (!volume || !*volume || !out_stat) {
        return -EINVAL;
    }
    fill_url(&parsed, url ? url : &(AFPShimURL){0});
    rc = afp_sl_statfs((afpc_volume_t *)volume, path ? path : "/", &parsed, out_stat);
    afp_sl_url_clear(&parsed);
    return shim_normalize_rc(rc);
}

int afp_shim_readdir(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url,
                     int start, int count, AFPShimDirEntry *out_entries, unsigned int *out_count, int *out_eod)
{
    struct afpc_url parsed;
    struct afpc_file_info *files = NULL;
    unsigned int numfiles = 0;
    int eod = 0;
    unsigned int i;
    int rc;

    if (!volume || !*volume || !path || !out_entries || !out_count) {
        return -EINVAL;
    }
    fill_url(&parsed, url ? url : &(AFPShimURL){0});
    rc = shim_normalize_rc(
        afp_sl_readdir((afpc_volume_t *)volume, path, &parsed, start, count, &numfiles, &files, &eod));
    afp_sl_url_clear(&parsed);
    if (rc != 0) {
        return rc;
    }
    for (i = 0; i < numfiles && i < (unsigned int)count; i++) {
        memset(&out_entries[i], 0, sizeof(out_entries[i]));
        strncpy(out_entries[i].name, files[i].name, sizeof(out_entries[i].name) - 1);
        out_entries[i].size = files[i].size;
        out_entries[i].mtime = files[i].modification_date;
        out_entries[i].mode = files[i].unixprivs.permissions;
        out_entries[i].is_directory = ((files[i].unixprivs.permissions & S_IFMT) == S_IFDIR);
    }
    free(files);
    *out_count = i;
    if (out_eod) {
        *out_eod = eod;
    }
    return 0;
}

int afp_shim_open(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, unsigned int mode, unsigned int *out_fileid)
{
    struct afpc_url parsed;
    int rc;

    if (!volume || !*volume || !path || !out_fileid) {
        return -EINVAL;
    }
    fill_url(&parsed, url ? url : &(AFPShimURL){0});
    rc = afp_sl_open((afpc_volume_t *)volume, path, &parsed, out_fileid, mode);
    afp_sl_url_clear(&parsed);
    return shim_normalize_rc(rc);
}

int afp_shim_close(AFPVolumeHandle *volume, unsigned int fileid)
{
    if (!volume || !*volume) {
        return -EINVAL;
    }
    return shim_normalize_rc(afp_sl_close((afpc_volume_t *)volume, fileid));
}

int afp_shim_read(AFPVolumeHandle *volume, unsigned int fileid, unsigned long long offset, unsigned int length,
                  char *buffer, unsigned int *out_received, unsigned int *out_eof)
{
    if (!volume || !*volume || !buffer || !out_received || !out_eof) {
        return -EINVAL;
    }
    return shim_normalize_rc(
        afp_sl_read((afpc_volume_t *)volume, fileid, 0, offset, length, out_received, out_eof, buffer));
}

int afp_shim_write(AFPVolumeHandle *volume, unsigned int fileid, unsigned long long offset,
                   const char *data, unsigned int size, unsigned int *out_written)
{
    if (!volume || !*volume || !data || !out_written) {
        return -EINVAL;
    }
    return shim_normalize_rc(
        afp_sl_write((afpc_volume_t *)volume, fileid, 0, offset, size, out_written, data));
}

int afp_shim_creat(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, mode_t mode)
{
    struct afpc_url parsed;
    int rc;
    fill_url(&parsed, url ? url : &(AFPShimURL){0});
    rc = afp_sl_creat((afpc_volume_t *)volume, path, &parsed, mode);
    afp_sl_url_clear(&parsed);
    return shim_normalize_rc(rc);
}

int afp_shim_mkdir(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, mode_t mode)
{
    struct afpc_url parsed;
    int rc;
    fill_url(&parsed, url ? url : &(AFPShimURL){0});
    rc = afp_sl_mkdir((afpc_volume_t *)volume, path, &parsed, mode);
    afp_sl_url_clear(&parsed);
    return shim_normalize_rc(rc);
}

int afp_shim_unlink(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url)
{
    struct afpc_url parsed;
    int rc;
    fill_url(&parsed, url ? url : &(AFPShimURL){0});
    rc = afp_sl_unlink((afpc_volume_t *)volume, path, &parsed);
    afp_sl_url_clear(&parsed);
    return shim_normalize_rc(rc);
}

int afp_shim_rmdir(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url)
{
    struct afpc_url parsed;
    int rc;
    fill_url(&parsed, url ? url : &(AFPShimURL){0});
    rc = afp_sl_rmdir((afpc_volume_t *)volume, path, &parsed);
    afp_sl_url_clear(&parsed);
    return shim_normalize_rc(rc);
}

int afp_shim_rename(AFPVolumeHandle *volume, const char *from, const char *to, const AFPShimURL *url)
{
    struct afpc_url parsed;
    int rc;
    fill_url(&parsed, url ? url : &(AFPShimURL){0});
    rc = afp_sl_rename((afpc_volume_t *)volume, from, to, &parsed);
    afp_sl_url_clear(&parsed);
    return shim_normalize_rc(rc);
}

int afp_shim_truncate(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, unsigned long long size)
{
    struct afpc_url parsed;
    int rc;
    fill_url(&parsed, url ? url : &(AFPShimURL){0});
    rc = afp_sl_truncate((afpc_volume_t *)volume, path, &parsed, size);
    afp_sl_url_clear(&parsed);
    return shim_normalize_rc(rc);
}

int afp_shim_chmod(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, mode_t mode)
{
    struct afpc_url parsed;
    int rc;
    fill_url(&parsed, url ? url : &(AFPShimURL){0});
    rc = afp_sl_chmod((afpc_volume_t *)volume, path, &parsed, mode);
    afp_sl_url_clear(&parsed);
    return shim_normalize_rc(rc);
}
