#ifndef MACDROID_CLIBARCHIVE_SHIM_H
#define MACDROID_CLIBARCHIVE_SHIM_H

/*
 * Minimal declarations for the stable public libarchive C API used by
 * ArchiveBrowserService. macOS ships libarchive with /usr/bin/tar, but does
 * not expose archive.h in the SDK, so keep this shim limited to opaque types
 * and exported functions documented by upstream libarchive.
 */

#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>

typedef int64_t la_int64_t;
typedef ssize_t la_ssize_t;

struct archive;
struct archive_entry;

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0
#define ARCHIVE_FORMAT_BASE_MASK 0xff0000
#define ARCHIVE_FORMAT_ZIP 0x50000

struct archive *archive_read_new(void);
int archive_read_support_filter_none(struct archive *);
int archive_read_support_format_zip_seekable(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_skip(struct archive *);
la_ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_has_encrypted_entries(struct archive *);
int archive_read_free(struct archive *);
int archive_errno(struct archive *);
const char *archive_error_string(struct archive *);

const char *archive_entry_pathname_utf8(struct archive_entry *);
la_int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

#endif
