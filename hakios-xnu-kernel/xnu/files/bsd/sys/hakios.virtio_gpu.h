/*
 * QEMU's virtio GPU (2D mode); see bsd/dev/hakios.virtio_gpu.c.
 */
#ifndef _SYS_HAKIOS_VIRTIO_GPU_H_
#define _SYS_HAKIOS_VIRTIO_GPU_H_

#include <mach/vm_param.h>

void hakios_virtio_gpu_init(void);   /* boot-arg virtio_gpu=1: QEMU's virtio GPU */

/* Phase 3: the window server's frames through the GPU (boot-arg virtio_present=1) */
vm_offset_t virtio_gpu_panel(uint32_t width, uint32_t height);
void virtio_gpu_present(vm_offset_t pixels, uint32_t width, uint32_t height, uint32_t stride);

#endif /* _SYS_HAKIOS_VIRTIO_GPU_H_ */
