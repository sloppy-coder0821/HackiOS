/*
 * QEMU's virtio GPU (2D mode) as the display behind MiniIOMobileFramebuffer:
 * what the phone's panel is there, in QEMU. Only with boot-arg virtio_gpu=1.
 *
 * "-device virtio-gpu-device" on the virt machine's virtio-mmio bus, modern
 * (non-legacy) transport like every other virtio device here
 * (-global virtio-mmio.force-legacy=false); qemu/run.sh gains it with
 * QEMU_GPU=1. The bus address is QEMU's and means nothing on the phone.
 *
 * Phase 1 (this file): find the device, shake hands, and read what scanouts
 * it has (GET_DISPLAY_INFO). Phase 2: a 2D test picture (below). Phase 3:
 * the window server's frames go through here too (virtio_gpu_panel() makes
 * a resource the size of the picture, virtio_gpu_present() copies a frame
 * into it and shows it), so that later 3D work has a working present path;
 * 3D (virgl) and the guest Mesa behind CoreAnimation's OpenGL ES path come
 * after that. No interrupt is used; control commands complete synchronously
 * by polling the used ring, the way the other virtio drivers here poll theirs.
 */
#include <kern/clock.h>
#include <libkern/libkern.h>
#include <mach/mach_types.h>
#include <mach/vm_param.h>
#include <pexpert/pexpert.h>
#include <sys/systm.h>
#include <vm/vm_kern.h>

#include <sys/hakios.virtio_gpu.h>

extern vm_offset_t ml_io_map(vm_offset_t phys_addr, vm_size_t size);
extern uint64_t kvtophys(vm_offset_t va);       /* pmap_paddr_t */

#define VIRTIO_BUS              0x0a000000UL    /* QEMU virt: 32 transports of 0x200 bytes */
#define VIRTIO_SLOTS            32
#define VIRTIO_SLOT_SIZE        0x200

#define VIRTIO_MAGIC            0x000           /* "virt" */
#define VIRTIO_VERSION          0x004
#define VIRTIO_DEVICE_ID        0x008
#define VIRTIO_DEVICE_FEATURES  0x010
#define VIRTIO_DEVICE_FEATURES_SEL 0x014
#define VIRTIO_DRIVER_FEATURES  0x020
#define VIRTIO_DRIVER_FEATURES_SEL 0x024
#define VIRTIO_QUEUE_SEL        0x030
#define VIRTIO_QUEUE_NUM_MAX    0x034
#define VIRTIO_QUEUE_NUM        0x038
#define VIRTIO_QUEUE_READY      0x044
#define VIRTIO_QUEUE_NOTIFY     0x050
#define VIRTIO_STATUS           0x070
#define VIRTIO_QUEUE_DESC       0x080
#define VIRTIO_QUEUE_DRIVER     0x090
#define VIRTIO_QUEUE_DEVICE     0x0a0

#define VIRTIO_ID_GPU           16
#define STATUS_ACKNOWLEDGE      1
#define STATUS_DRIVER           2
#define STATUS_DRIVER_OK        4
#define STATUS_FEATURES_OK      8

#define QUEUE_SIZE              256             /* control queue: room for one attach's pages */
#define QUEUE_CONTROL           0
#define DESC_F_NEXT             1
#define DESC_F_WRITE            2
#define AVAIL_F_NO_INTERRUPT    1

/* one page for the rings, one for a command and its answer */
#define OFFSET_DESC             0x0000
#define OFFSET_AVAIL            0x1000
#define OFFSET_USED             0x2000
#define RING_PAGES              3
#define CMD_SIZE                256
#define RESP_SIZE               1024

struct vq_desc {
	uint64_t addr;
	uint32_t len;
	uint16_t flags;
	uint16_t next;
};
struct vq_avail {
	uint16_t flags;
	uint16_t idx;
	uint16_t ring[QUEUE_SIZE];
};
struct vq_used {
	uint16_t flags;
	uint16_t idx;
	struct {
		uint32_t id;
		uint32_t len;
	} ring[QUEUE_SIZE];
};

/* virtio-gpu commands (little-endian on the wire; the machine is little-endian) */
struct gpu_ctrl_hdr {
	uint32_t type;
	uint32_t flags;
	uint64_t fence_id;
	uint32_t ctx_id;
	uint32_t padding;
};
struct gpu_rect {
	uint32_t x, y, width, height;
};
struct gpu_display_one {
	struct gpu_rect r;
	uint32_t enabled;
	uint32_t flags;
};
#define GPU_CMD_GET_DISPLAY_INFO        0x0100
#define GPU_RESP_OK_DISPLAY_INFO        0x1101
#define GPU_MAX_SCANOUTS                16
/* 2D resource commands (Phase 2) */
struct gpu_resource_create_2d {
	uint32_t resource_id, format, width, height;
};
struct gpu_attach_backing {
	uint32_t resource_id, nr_entries;
};
struct gpu_mem_entry {
	uint64_t addr;
	uint32_t length, padding;
};
struct gpu_set_scanout {
	struct gpu_rect r;
	uint32_t scanout_id, resource_id;
};
struct gpu_transfer_2d {
	struct gpu_rect r;
	uint64_t offset;
	uint32_t resource_id, padding;
};
struct gpu_flush {
	struct gpu_rect r;
	uint32_t resource_id, padding;
};
#define GPU_CMD_CREATE_2D               0x0101
#define GPU_CMD_SET_SCANOUT             0x0103
#define GPU_CMD_FLUSH                   0x0104
#define GPU_CMD_TRANSFER_2D             0x0105
#define GPU_CMD_ATTACH_BACKING          0x0106
#define GPU_RESP_OK_NODATA              0x1100
#define GPU_FORMAT_XRGB                 2       /* B8G8R8X8_UNORM: opaque, no alpha to get wrong */
#define GPU_TEST_RESOURCE               1
#define GPU_TEST_MAX_BYTES              (16 << 20)

static vm_offset_t virtio;                      /* the device's registers */
static struct vq_desc *desc;
static struct vq_avail *avail;
static struct vq_used *used;
static uint8_t *cmd_buf, *resp_buf;
static uint16_t seen;                           /* how far the used ring has been read */

static inline uint32_t
reg_read(uint32_t reg)
{
	return *(volatile uint32_t *)(virtio + reg);
}

static inline void
reg_write(uint32_t reg, uint32_t value)
{
	*(volatile uint32_t *)(virtio + reg) = value;
}

static inline void
reg_write64(uint32_t reg, uint64_t value)
{
	reg_write(reg, (uint32_t)value);
	reg_write(reg + 4, (uint32_t)(value >> 32));
}

/*
 * One control command and its answer: the command at first, an optional data
 * segment (ATTACH_BACKING's memory entries) after it, the answer last, chained
 * as two or three descriptors. Returns the answer's header, or NULL when the
 * device did not answer in time or answered another kind.
 */
static struct gpu_ctrl_hdr *
gpu_command3(uint32_t type, const void *cmd, uint32_t cmd_len,
    const void *extra, uint32_t extra_len, uint32_t resp_len, uint32_t want)
{
	struct gpu_ctrl_hdr *hdr = (struct gpu_ctrl_hdr *)cmd_buf;
	struct gpu_ctrl_hdr *answer = (struct gpu_ctrl_hdr *)resp_buf;
	uint64_t spins = 0;
	unsigned ndesc = 1;

	if (cmd_len > CMD_SIZE - sizeof(*hdr) || resp_len > RESP_SIZE) {
		return NULL;
	}
	bzero(cmd_buf, CMD_SIZE);
	hdr->type = type;
	if (cmd_len) {
		memcpy(cmd_buf + sizeof(*hdr), cmd, cmd_len);
	}
	desc[0].addr = kvtophys((vm_offset_t)cmd_buf);
	desc[0].len = (uint32_t)(sizeof(*hdr) + cmd_len);
	desc[0].flags = DESC_F_NEXT;    /* always: the answer (after any data) follows */
	desc[0].next = 1;
	if (extra_len) {
		/* the caller keeps the entries in extra; hand them over whole */
		desc[1].addr = kvtophys((vm_offset_t)extra);
		desc[1].len = extra_len;
		desc[1].flags = DESC_F_NEXT;
		desc[1].next = 2;
		ndesc = 2;
	}
	desc[ndesc].addr = kvtophys((vm_offset_t)resp_buf);
	desc[ndesc].len = resp_len;
	desc[ndesc].flags = DESC_F_WRITE;
	bzero(resp_buf, RESP_SIZE);
	avail->ring[avail->idx % QUEUE_SIZE] = 0;
	__builtin_arm_dmb(0xb);         /* ISH */
	avail->idx++;
	__builtin_arm_dmb(0xb);         /* ISH */
	reg_write(VIRTIO_QUEUE_NOTIFY, QUEUE_CONTROL);
	while (seen == *(volatile uint16_t *)&used->idx) {
		if (++spins > 100000000) {
			printf("virtio-gpu: command %#x: no answer\n", type);
			return NULL;
		}
	}
	seen++;
	__builtin_arm_dmb(0xb);         /* ISH */
	/* the answer is the device's DMA, invisible to the compiler: read it
	   back through volatile (a plain read would be folded to the bzero above) */
	__asm__ volatile("" ::: "memory");
	if (*(volatile uint32_t *)&answer->type != want) {
		printf("virtio-gpu: command %#x answered %#x, not %#x\n",
		    type, *(volatile uint32_t *)&answer->type, want);
		return NULL;
	}
	return answer;
}

static struct gpu_ctrl_hdr *
gpu_command(uint32_t type, const void *cmd, uint32_t cmd_len, uint32_t resp_len, uint32_t want)
{
	return gpu_command3(type, cmd, cmd_len, NULL, 0, resp_len, want);
}

static bool
virtio_gpu_attach(uint32_t resource, vm_offset_t fb, uint32_t size)
{
	struct gpu_attach_backing cmd;
	struct gpu_mem_entry *ents;
	vm_offset_t ents_page = 0;
	uint32_t pages = (size + PAGE_SIZE - 1) / PAGE_SIZE, i, last;
	bool ok;

	/*
	 * The device is handed an ARRAY of address/length pairs (one
	 * descriptor for the whole array), through which it then maps the
	 * framebuffer's pages itself. The array must be physically whole:
	 * one page holds 256 entries (4 MB of 16K pages), enough for any
	 * scanout QEMU offers here.
	 */
	if (pages == 0 || (uint64_t)pages * sizeof(*ents) > PAGE_SIZE) {
		printf("virtio-gpu: %u pages do not fit one entries page\n", pages);
		return false;
	}
	if (kmem_alloc(kernel_map, &ents_page, PAGE_SIZE, KMA_KOBJECT | KMA_ZERO | KMA_DATA,
	    VM_KERN_MEMORY_IOKIT) != KERN_SUCCESS) {
		printf("virtio-gpu: no memory for the entries\n");
		return false;
	}
	ents = (struct gpu_mem_entry *)ents_page;
	for (i = 0; i < pages; i++) {
		last = (i == pages - 1) ? size - i * PAGE_SIZE : PAGE_SIZE;
		ents[i].addr = kvtophys(fb + (vm_offset_t)i * PAGE_SIZE);
		ents[i].length = last;
		ents[i].padding = 0;
	}
	cmd.resource_id = resource;
	cmd.nr_entries = pages;
	ok = gpu_command3(GPU_CMD_ATTACH_BACKING, &cmd, sizeof(cmd),
	    ents, pages * (uint32_t)sizeof(*ents),
	    (uint32_t)sizeof(struct gpu_ctrl_hdr), GPU_RESP_OK_NODATA) != NULL;
	kmem_free(kernel_map, ents_page, PAGE_SIZE);
	return ok;
}

/*
 * A 256x256 test picture in the scanout's corner: eight colour bars. Small
 * on purpose (64 pages fit any control queue); a full-size resource comes
 * once this path has shown itself on the host's screen.
 */
static bool
virtio_gpu_test_pattern(uint32_t scanout)
{
	static const uint32_t bars[8] = {
		0x00000000, 0x00ff0000, 0x0000ff00, 0x000000ff,
		0x00ffff00, 0x0000ffff, 0x00ff00ff, 0x00ffffff,
	};
	struct gpu_resource_create_2d create;
	struct gpu_set_scanout so;
	struct gpu_transfer_2d tr;
	struct gpu_flush fl;
	vm_offset_t fb = 0;
	uint32_t *px, x, y, size = 64 * 64 * 4;

	if (kmem_alloc(kernel_map, &fb, size, KMA_KOBJECT | KMA_ZERO | KMA_DATA,
	    VM_KERN_MEMORY_IOKIT) != KERN_SUCCESS) {
		printf("virtio-gpu: no memory for the test picture\n");
		return false;
	}
	px = (uint32_t *)fb;
	for (y = 0; y < 64; y++) {
		for (x = 0; x < 64; x++) {
			px[y * 64 + x] = bars[(x / 8) % 8];
		}
	}
	printf("virtio-gpu: picture at va %#llx phys %#llx\n",
	    (unsigned long long)fb, (unsigned long long)kvtophys(fb));
	create.resource_id = GPU_TEST_RESOURCE;
	create.format = GPU_FORMAT_XRGB;
	create.width = 64;
	create.height = 64;
	if (gpu_command(GPU_CMD_CREATE_2D, &create, sizeof(create),
	    (uint32_t)sizeof(struct gpu_ctrl_hdr), GPU_RESP_OK_NODATA) == NULL) {
		return false;
	}
	if (!virtio_gpu_attach(GPU_TEST_RESOURCE, fb, size)) {
		return false;
	}
	so.r.x = so.r.y = 0;
	so.r.width = so.r.height = 64;
	so.scanout_id = scanout;
	so.resource_id = GPU_TEST_RESOURCE;
	if (gpu_command(GPU_CMD_SET_SCANOUT, &so, sizeof(so),
	    (uint32_t)sizeof(struct gpu_ctrl_hdr), GPU_RESP_OK_NODATA) == NULL) {
		return false;
	}
	tr.r = so.r;
	tr.offset = 0;
	tr.resource_id = GPU_TEST_RESOURCE;
	tr.padding = 0;
	if (gpu_command(GPU_CMD_TRANSFER_2D, &tr, sizeof(tr),
	    (uint32_t)sizeof(struct gpu_ctrl_hdr), GPU_RESP_OK_NODATA) == NULL) {
		return false;
	}
	fl.r = so.r;
	fl.resource_id = GPU_TEST_RESOURCE;
	fl.padding = 0;
	if (gpu_command(GPU_CMD_FLUSH, &fl, sizeof(fl),
	    (uint32_t)sizeof(struct gpu_ctrl_hdr), GPU_RESP_OK_NODATA) == NULL) {
		return false;
	}
	printf("virtio-gpu: test picture up on scanout %u (kept: %u KB)\n", scanout, size >> 10);
	return true;
}

static bool
virtio_gpu_start(void)
{
	vm_offset_t bus = ml_io_map(VIRTIO_BUS, VIRTIO_SLOTS * VIRTIO_SLOT_SIZE);
	vm_offset_t rings = 0, ios = 0;
	struct gpu_ctrl_hdr *answer;
	struct gpu_display_one *outs;
	int slot, i;

	for (slot = 0; slot < VIRTIO_SLOTS; slot++) {
		virtio = bus + (vm_offset_t)slot * VIRTIO_SLOT_SIZE;
		if (reg_read(VIRTIO_MAGIC) == 0x74726976 && reg_read(VIRTIO_DEVICE_ID) == VIRTIO_ID_GPU) {
			break;
		}
	}
	if (slot == VIRTIO_SLOTS) {
		printf("virtio-gpu: no GPU device (start QEMU with -device virtio-gpu-device)\n");
		return false;
	}
	if (reg_read(VIRTIO_VERSION) != 2) {
		printf("virtio-gpu: slot %d is a legacy transport; start QEMU with -global virtio-mmio.force-legacy=false\n",
		    slot);
		return false;
	}
	reg_write(VIRTIO_STATUS, 0);            /* reset */
	reg_write(VIRTIO_STATUS, STATUS_ACKNOWLEDGE);
	reg_write(VIRTIO_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);
	reg_write(VIRTIO_DEVICE_FEATURES_SEL, 1);
	reg_write(VIRTIO_DRIVER_FEATURES_SEL, 1);
	reg_write(VIRTIO_DRIVER_FEATURES, 1);   /* bit 32: VIRTIO_F_VERSION_1, and nothing else */
	reg_write(VIRTIO_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);
	if (!(reg_read(VIRTIO_STATUS) & STATUS_FEATURES_OK)) {
		printf("virtio-gpu: slot %d: features refused\n", slot);
		return false;
	}
	reg_write(VIRTIO_QUEUE_SEL, QUEUE_CONTROL);
	if (reg_read(VIRTIO_QUEUE_NUM_MAX) < QUEUE_SIZE) {
		printf("virtio-gpu: control queue holds only %u\n", reg_read(VIRTIO_QUEUE_NUM_MAX));
		return false;
	}
	if (kmem_alloc(kernel_map, &rings, RING_PAGES * PAGE_SIZE, KMA_KOBJECT | KMA_ZERO | KMA_DATA,
	    VM_KERN_MEMORY_IOKIT) != KERN_SUCCESS ||
	    kmem_alloc(kernel_map, &ios, PAGE_SIZE, KMA_KOBJECT | KMA_ZERO | KMA_DATA,
	    VM_KERN_MEMORY_IOKIT) != KERN_SUCCESS) {
		printf("virtio-gpu: no memory for the control queue\n");
		return false;
	}
	desc = (struct vq_desc *)(rings + OFFSET_DESC);
	avail = (struct vq_avail *)(rings + OFFSET_AVAIL);
	used = (struct vq_used *)(rings + OFFSET_USED);
	cmd_buf = (uint8_t *)ios;
	resp_buf = (uint8_t *)ios + PAGE_SIZE / 2;
	avail->flags = AVAIL_F_NO_INTERRUPT;
	reg_write(VIRTIO_QUEUE_NUM, QUEUE_SIZE);
	reg_write64(VIRTIO_QUEUE_DESC, kvtophys(rings) + OFFSET_DESC);
	reg_write64(VIRTIO_QUEUE_DRIVER, kvtophys(rings) + OFFSET_AVAIL);
	reg_write64(VIRTIO_QUEUE_DEVICE, kvtophys(rings) + OFFSET_USED);
	__builtin_arm_dmb(0xb);         /* ISH */
	reg_write(VIRTIO_QUEUE_READY, 1);
	reg_write(VIRTIO_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);
	answer = gpu_command(GPU_CMD_GET_DISPLAY_INFO, NULL, 0,
	    (uint32_t)(sizeof(*answer) + GPU_MAX_SCANOUTS * sizeof(*outs)), GPU_RESP_OK_DISPLAY_INFO);
	if (answer == NULL) {
		return false;
	}
	outs = (struct gpu_display_one *)((uint8_t *)answer + sizeof(*answer));
	for (i = 0; i < GPU_MAX_SCANOUTS; i++) {
		if (outs[i].enabled) {
			printf("virtio-gpu: scanout %d: %ux%u at %u,%u\n",
			    i, outs[i].r.width, outs[i].r.height, outs[i].r.x, outs[i].r.y);
		}
	}
	printf("virtio-gpu: display device in slot %d\n", slot);
	virtio_gpu_test_pattern(0);
	return true;
}

void
hakios_virtio_gpu_init(void)
{
	uint32_t enabled = 0;

	if (!PE_parse_boot_argn("virtio_gpu", &enabled, sizeof(enabled)) || !enabled) {
		return;
	}
	if (!virtio_gpu_start()) {
		printf("virtio-gpu: not started\n");
	}
}

/* ---- Phase 3: the window server's frames through here ---------------------- */

#define GPU_PANEL_RESOURCE          2       /* beside the test picture's 1 */
static vm_offset_t panel_fb;
static uint32_t panel_width, panel_height;

/*
 * A resource the size of the picture the window server draws (fWidth by
 * fHeight: 375x812 at fbscale=1), shown on scanout 0. The first call makes
 * it; later calls with another size are refused (the size never changes in
 * a session). Returns the framebuffer's address for the caller to draw
 * into, or 0. Only with boot-arg virtio_present=1 (beside virtio_gpu=1):
 * presenting mirrors ramfb until this path is trusted with the panel.
 */
vm_offset_t
virtio_gpu_panel(uint32_t width, uint32_t height)
{
	struct gpu_resource_create_2d create;
	struct gpu_set_scanout so;
	uint64_t size = (uint64_t)width * height * 4;

	if (width == 0 || height == 0 || size > GPU_TEST_MAX_BYTES) {
		return 0;
	}
	if (panel_fb != 0) {
		return (panel_width == width && panel_height == height) ? panel_fb : 0;
	}
	if (kmem_alloc(kernel_map, &panel_fb, (vm_size_t)size,
	    KMA_KOBJECT | KMA_ZERO | KMA_DATA, VM_KERN_MEMORY_IOKIT) != KERN_SUCCESS) {
		panel_fb = 0;
		printf("virtio-gpu: no memory for the panel\n");
		return 0;
	}
	panel_width = width;
	panel_height = height;
	create.resource_id = GPU_PANEL_RESOURCE;
	create.format = GPU_FORMAT_XRGB;
	create.width = width;
	create.height = height;
	if (gpu_command(GPU_CMD_CREATE_2D, &create, sizeof(create),
	    (uint32_t)sizeof(struct gpu_ctrl_hdr), GPU_RESP_OK_NODATA) == NULL ||
	    !virtio_gpu_attach(GPU_PANEL_RESOURCE, panel_fb, (uint32_t)size)) {
		panel_fb = 0;
		return 0;
	}
	so.r.x = so.r.y = 0;
	so.r.width = width;
	so.r.height = height;
	so.scanout_id = 0;
	so.resource_id = GPU_PANEL_RESOURCE;
	if (gpu_command(GPU_CMD_SET_SCANOUT, &so, sizeof(so),
	    (uint32_t)sizeof(struct gpu_ctrl_hdr), GPU_RESP_OK_NODATA) == NULL) {
		panel_fb = 0;
		return 0;
	}
	printf("virtio-gpu: panel %ux%u up\n", width, height);
	return panel_fb;
}

/*
 * A frame the caller has drawn: copy it into the panel resource (row by row,
 * the caller's stride may differ) and show it. The copy is the last CPU cost
 * on this path; rendering into the resource directly comes with the display
 * taking it over from ramfb.
 */
void
virtio_gpu_present(vm_offset_t pixels, uint32_t width, uint32_t height, uint32_t stride)
{
	struct gpu_transfer_2d tr;
	struct gpu_flush fl;
	uint8_t *dst = (uint8_t *)panel_fb, *src = (uint8_t *)pixels;
	uint32_t y;

	if (panel_fb == 0 || width != panel_width || height != panel_height) {
		return;
	}
	for (y = 0; y < height; y++) {
		memcpy(dst + (size_t)y * width * 4, src + (size_t)y * stride, (size_t)width * 4);
	}
	tr.r.x = tr.r.y = 0;
	tr.r.width = width;
	tr.r.height = height;
	tr.offset = 0;
	tr.resource_id = GPU_PANEL_RESOURCE;
	tr.padding = 0;
	if (gpu_command(GPU_CMD_TRANSFER_2D, &tr, sizeof(tr),
	    (uint32_t)sizeof(struct gpu_ctrl_hdr), GPU_RESP_OK_NODATA) == NULL) {
		return;
	}
	fl.r = tr.r;
	fl.resource_id = GPU_PANEL_RESOURCE;
	fl.padding = 0;
	gpu_command(GPU_CMD_FLUSH, &fl, sizeof(fl),
	    (uint32_t)sizeof(struct gpu_ctrl_hdr), GPU_RESP_OK_NODATA);
}
