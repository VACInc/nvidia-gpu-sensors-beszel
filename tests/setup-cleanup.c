/*
 * gpu_setup() failure cleanup, against a fake RM. RM handles are derived from
 * the slot index, so when one GPU fails after its device object is allocated
 * the next GPU reuses the same handle: the stale object must be freed (and its
 * device fd closed) or the next GPU fails with a duplicate handle.
 */
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
static int fake_open(const char *path, int flags, ...);
static int fake_close(int fd);
static int fake_ioctl(int fd, unsigned long req, ...);
#define open fake_open
#define close fake_close
#define ioctl fake_ioctl
#define main collector_main
#include "../src/nvidia-gpu-sensors.c"
#undef main
#undef open
#undef close
#undef ioctl
#include <assert.h>

#define FAKE_FD 1000
static int open_fds[64];
static NvHandle live[64];
static int fail_next_subdev;

static int fake_open(const char *path, int flags, ...)
{
    (void)path; (void)flags;
    for (int i = 0; i < 64; i++)
        if (!open_fds[i]) {
            open_fds[i] = 1;
            return FAKE_FD + i;
        }
    errno = EMFILE;
    return -1;
}

static int fake_close(int fd)
{
    assert(fd >= FAKE_FD && fd < FAKE_FD + 64 && open_fds[fd - FAKE_FD]);
    open_fds[fd - FAKE_FD] = 0;
    return 0;
}

static int n_open(void)
{
    int n = 0;
    for (int i = 0; i < 64; i++)
        n += open_fds[i];
    return n;
}

static int is_live(NvHandle h)
{
    for (int i = 0; i < 64; i++)
        if (live[i] == h)
            return 1;
    return 0;
}

static int fake_ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    va_start(ap, req);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    (void)fd;
    switch (_IOC_NR(req)) {
    case NV_ESC_WAIT_OPEN_COMPLETE:
    case NV_ESC_REGISTER_FD:
        return 0;
    case NV_ESC_RM_MAP_MEMORY:
        ((NVOS33_FD *)arg)->status = 0x56;   /* RUSD map refused */
        return 0;
    case NV_ESC_RM_CONTROL: {
        NVOS54 *p = arg;
        if (p->cmd == NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2) {
            IDINFO_V2 *idi = (IDINFO_V2 *)(uintptr_t)p->params;
            idi->deviceInstance = idi->gpuId & 0xff;
            p->status = 0;
        } else {
            p->status = 0x56;   /* NV_ERR_NOT_SUPPORTED */
        }
        return 0;
    }
    case NV_ESC_RM_ALLOC: {
        NVOS21 *p = arg;
        if (is_live(p->hObjectNew)) {
            p->status = 0x1e;   /* NV_ERR_INSERT_DUPLICATE_NAME */
            return 0;
        }
        if (p->hClass == NV20_SUBDEVICE_0 && fail_next_subdev) {
            fail_next_subdev = 0;
            p->status = 0x40;   /* NV_ERR_OPERATING_SYSTEM */
            return 0;
        }
        for (int i = 0; i < 64; i++)
            if (!live[i]) {
                live[i] = p->hObjectNew;
                break;
            }
        p->status = 0;
        return 0;
    }
    case NV_ESC_RM_FREE: {
        NVOS00 *p = arg;
        for (int i = 0; i < 64; i++)
            if (live[i] == p->hObjectOld)
                live[i] = 0;
        /* children: device 0xCB000002+n*0x10 owns subdevice +1, RUSD +2 */
        for (int i = 0; i < 64; i++)
            if (live[i] == p->hObjectOld + 1 || live[i] == p->hObjectOld + 2)
                live[i] = 0;
        p->status = 0;
        return 0;
    }
    }
    errno = ENOTTY;
    return -1;
}

int main(void)
{
    static GPU gpus[2];
    NvHandle hClient = 0xCB000001;

    /* First GPU fails at the subdevice step, in slot 0. */
    fail_next_subdev = 1;
    assert(gpu_setup(&gpus[0], hClient, 0x100, 0) == -1);
    assert(n_open() == 0);          /* device fd closed */
    assert(!is_live(0xCB000002));   /* device object freed */

    /* The next GPU reuses slot 0 and must come up. */
    assert(gpu_setup(&gpus[0], hClient, 0x200, 0) == 0);
    assert(is_live(0xCB000002) && is_live(0xCB000003));
    /* only the kept device fd: the RUSD map fd is closed after map failure */
    assert(n_open() == 1);
    return 0;
}
