#include "42-text-conversion.h"

#if !ICICLE_NO_INPUT

typedef struct {
    const iint_t  entity_size;
    const iint_t  count;
    const char    entity[0];
/*  const char    entity[entity_size + 1]; */
/*  const itime_t times[count];            */
} ichord_t;

typedef struct {
    const iint_t   magic;   /* CHORDATA */
    const iint_t   version; /* 1 */
    const iint_t   max_chord_count;
    const ichord_t chords[0];
} ichord_header_t;

typedef struct {
    void           *mapped_ptr;
    size_t          mapped_size;
    iint_t          max_chord_count;
    const ichord_t *chords;
} ichord_file_t;

static ierror_msg_t ichord_file_mmap (int fd, ichord_file_t *file)
{
    static ichord_file_t empty;
    *file = empty;

    if (fd == 0) {
        file->max_chord_count = 1;
        return 0;
    }

    struct stat stat;
    int stat_error = fstat (fd, &stat);

    if (stat_error != 0)
        return ierror_msg_alloc ("failed to stat chord file", 0, 0);

    size_t mapped_size = stat.st_size;
    void  *mapped_ptr  = mmap (0, mapped_size, PROT_READ, MAP_PRIVATE, fd, 0);

    if (mapped_ptr == MAP_FAILED)
        return ierror_msg_alloc ("failed to memory map chord file", 0, 0);

    file->mapped_ptr  = mapped_ptr;
    file->mapped_size = mapped_size;

    ichord_header_t *hdr = mapped_ptr;

#if ICICLE_DEBUG
    fprintf (stderr, "ichord_file_mmap: mapped %zu bytes to %p\n", mapped_size, mapped_ptr);
    fprintf (stderr, "ichord_file_mmap: magic           = 0x%08" PRIx64 "\n", hdr->magic);
    fprintf (stderr, "ichord_file_mmap: version         = %" PRId64 "\n",     hdr->version);
    fprintf (stderr, "ichord_file_mmap: max_chord_count = %" PRId64 "\n",     hdr->max_chord_count);
    fprintf (stderr, "ichord_file_mmap: chords          = %p\n",       hdr->chords);
#endif

    if (hdr->magic != 0x41544144524f4843 /* CHORDATA */)
        return ierror_msg_alloc ("invalid magic number in chord file", 0, 0);

    if (hdr->version != 1)
        return ierror_msg_alloc ("only version 1 chord files are supported", 0, 0);

    file->max_chord_count = hdr->max_chord_count;
    file->chords          = hdr->chords;

    return 0;
}

static ierror_msg_t ichord_file_unmap (const ichord_file_t *file)
{
    if (file->mapped_ptr == 0)
        return 0;

    int error = munmap ((void *)file->mapped_ptr, file->mapped_size);

    if (error != 0)
        return ierror_msg_alloc ("failed to unmap chord file", 0, 0);

    return 0;
}

static const itime_t * INLINE ichord_times (const ichord_t *chord)
{
    size_t      entity0_size = (size_t) chord->entity_size + 1;
    const char* entity_end   = chord->entity + entity0_size;

    return (const itime_t *)entity_end;
}

static const ichord_t * INLINE ichord_next (const ichord_t *chord)
{
    const itime_t  *time_end = ichord_times (chord) + chord->count;
    const ichord_t *next     = (const ichord_t *)time_end;

    return next->entity_size == 0 ? 0 : next;
}

static const ichord_t * INLINE ichord_scan (const ichord_t *chord, const char *entity, size_t entity_size, iint_t *chord_count, const itime_t **chord_times)
{
    while (chord != 0) {
        size_t cmp_size = 1 + MIN (entity_size, (size_t)chord->entity_size);
        int    cmp      = memcmp (entity, chord->entity, cmp_size);

        /* current chord record matches this entity, extract the times and move to the next chord */
        if (cmp == 0) {
            *chord_count = chord->count;
            *chord_times = ichord_times (chord);

            return ichord_next (chord);
        }

        /* current chord record is for a later entity, leave it as the current */
        if (cmp < 1) {
            break;
        }

        /* current chord record is for an earlier entity, move to the next chord */
        chord = ichord_next (chord);

        /* TODO this indicates that we missed an entity, should we do something about this? */
    }

    *chord_count = 0;
    *chord_times = 0;
    return chord;
}

#endif
