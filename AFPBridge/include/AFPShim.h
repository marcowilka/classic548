#ifndef CLASSICAFP_AFP_SHIM_H
#define CLASSICAFP_AFP_SHIM_H

#include <stdint.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *AFPServerHandle;
typedef void *AFPVolumeHandle;

typedef struct AFPShimURL {
    char username[128];
    char password[128];
    char servername[256];
    char volumename[256];
    char path[1024];
    int port;
} AFPShimURL;

typedef struct AFPShimDirEntry {
    char name[1024];
    uint64_t size;
    int is_directory;
    int64_t mtime;
    uint32_t mode;
} AFPShimDirEntry;

unsigned int afp_shim_default_uams(void);
unsigned int afp_shim_guest_uams(void);
int afp_shim_exit(void);

int afp_shim_connect(const AFPShimURL *url, unsigned int uam_mask, AFPServerHandle *out_server);
int afp_shim_resume(const AFPShimURL *url, unsigned int uam_mask, AFPServerHandle *out_server);
int afp_shim_disconnect(AFPServerHandle *server);

int afp_shim_attach(AFPServerHandle server, const AFPShimURL *url, AFPVolumeHandle *out_volume, int *needs_vol_password);
int afp_shim_detach(AFPVolumeHandle *volume, const AFPShimURL *url);

int afp_shim_list_volumes(AFPServerHandle server, const AFPShimURL *url, char *out_names, size_t out_size, unsigned int *out_count);
int afp_shim_stat(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, struct stat *out_stat);
int afp_shim_statfs(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, struct statvfs *out_stat);

int afp_shim_readdir(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url,
                     int start, int count, AFPShimDirEntry *out_entries, unsigned int *out_count, int *out_eod);

int afp_shim_open(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, unsigned int mode, unsigned int *out_fileid);
int afp_shim_close(AFPVolumeHandle *volume, unsigned int fileid);
int afp_shim_read(AFPVolumeHandle *volume, unsigned int fileid, unsigned long long offset, unsigned int length,
                  char *buffer, unsigned int *out_received, unsigned int *out_eof);
int afp_shim_write(AFPVolumeHandle *volume, unsigned int fileid, unsigned long long offset,
                   const char *data, unsigned int size, unsigned int *out_written);

int afp_shim_creat(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, mode_t mode);
int afp_shim_mkdir(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, mode_t mode);
int afp_shim_unlink(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url);
int afp_shim_rmdir(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url);
int afp_shim_rename(AFPVolumeHandle *volume, const char *from, const char *to, const AFPShimURL *url);
int afp_shim_truncate(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, unsigned long long size);
int afp_shim_chmod(AFPVolumeHandle *volume, const char *path, const AFPShimURL *url, mode_t mode);

#ifdef __cplusplus
}
#endif

#endif
