#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-server.h>
#include "xdg-shell-server-protocol.h"
#include "text-input-server-protocol.h"

static struct wl_display *display;
static struct wl_event_loop *loop;
static struct wl_event_source *timer;
static struct wl_resource *surface_res, *text_input_res, *buffer_res;
static uint32_t commits;
static int step;
static const char *scenario;
static const char *dump_dir;

static void dump(const char *name)
{
	char path[512];
	snprintf(path, sizeof path, "%s/%s", dump_dir, name);
	if (!buffer_res) {
		fprintf(stderr, "FAKE no buffer to dump\n");
		return;
	}
	struct wl_shm_buffer *buffer = wl_shm_buffer_get(buffer_res);
	int w = wl_shm_buffer_get_width(buffer);
	int h = wl_shm_buffer_get_height(buffer);
	int stride = wl_shm_buffer_get_stride(buffer);
	wl_shm_buffer_begin_access(buffer);
	uint8_t *data = wl_shm_buffer_get_data(buffer);
	FILE *f = fopen(path, "wb");
	fprintf(f, "P6\n%d %d\n255\n", w, h);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			uint8_t *p = data + y * stride + x * 4;
			fputc(p[0], f);
			fputc(p[1], f);
			fputc(p[2], f);
		}
	}
	fclose(f);
	wl_shm_buffer_end_access(buffer);
	fprintf(stderr, "FAKE dumped %s %dx%d\n", name, w, h);
}

static void send_done(void)
{
	zwp_text_input_v3_send_done(text_input_res, commits);
}

static int tick(void *data)
{
	(void)data;
	if (strcmp(scenario, "ime") != 0) {
		fprintf(stderr, "FAKE terminating\n");
		wl_display_terminate(display);
		return 0;
	}
	switch (step) {
	case 0:
		fprintf(stderr, "FAKE send enter\n");
		zwp_text_input_v3_send_enter(text_input_res, surface_res);
		break;
	case 1:
		fprintf(stderr, "FAKE send preedit ka\n");
		zwp_text_input_v3_send_preedit_string(text_input_res, "ka", 0, 2);
		send_done();
		break;
	case 2:
		fprintf(stderr, "FAKE send preedit kan\n");
		zwp_text_input_v3_send_preedit_string(text_input_res, "kan", 0, 3);
		send_done();
		break;
	case 3:
		dump("preedit.ppm");
		break;
	case 4:
		fprintf(stderr, "FAKE send commit\n");
		zwp_text_input_v3_send_commit_string(text_input_res, "かん");
		send_done();
		break;
	case 5:
		dump("committed.ppm");
		break;
	case 6:
		fprintf(stderr, "FAKE send leave\n");
		zwp_text_input_v3_send_leave(text_input_res, surface_res);
		break;
	default:
		wl_display_terminate(display);
		return 0;
	}
	step++;
	wl_event_source_timer_update(timer, 1200);
	return 0;
}

static void surface_destroy(struct wl_client *c, struct wl_resource *r) { wl_resource_destroy(r); }
static void surface_attach(struct wl_client *c, struct wl_resource *r, struct wl_resource *buf, int32_t x, int32_t y) { buffer_res = buf; }
static void surface_damage(struct wl_client *c, struct wl_resource *r, int32_t x, int32_t y, int32_t w, int32_t h) {}
static void surface_frame(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
	struct wl_resource *cb = wl_resource_create(c, &wl_callback_interface, 1, id);
	wl_callback_send_done(cb, 0);
	wl_resource_destroy(cb);
}
static void surface_region(struct wl_client *c, struct wl_resource *r, struct wl_resource *reg) {}
static void surface_commit(struct wl_client *c, struct wl_resource *r)
{
	if (buffer_res)
		wl_buffer_send_release(buffer_res);
}
static void surface_int(struct wl_client *c, struct wl_resource *r, int32_t v) {}
static void surface_damage_buffer(struct wl_client *c, struct wl_resource *r, int32_t x, int32_t y, int32_t w, int32_t h) {}
static void surface_offset(struct wl_client *c, struct wl_resource *r, int32_t x, int32_t y) {}
static const struct wl_surface_interface surface_impl = {
	surface_destroy, surface_attach, surface_damage, surface_frame, surface_region, surface_region,
	surface_commit, surface_int, surface_int, surface_damage_buffer, surface_offset,
};

static void compositor_create_surface(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
	struct wl_resource *s = wl_resource_create(c, &wl_surface_interface, wl_resource_get_version(r), id);
	wl_resource_set_implementation(s, &surface_impl, NULL, NULL);
}
static void compositor_create_region(struct wl_client *c, struct wl_resource *r, uint32_t id) {}
static const struct wl_compositor_interface compositor_impl = { compositor_create_surface, compositor_create_region };
static void compositor_bind(struct wl_client *c, void *d, uint32_t v, uint32_t id)
{
	struct wl_resource *r = wl_resource_create(c, &wl_compositor_interface, v, id);
	wl_resource_set_implementation(r, &compositor_impl, NULL, NULL);
}

static void toplevel_destroy(struct wl_client *c, struct wl_resource *r) { wl_resource_destroy(r); }
static void toplevel_parent(struct wl_client *c, struct wl_resource *r, struct wl_resource *p) {}
static void toplevel_string(struct wl_client *c, struct wl_resource *r, const char *s) {}
static void toplevel_menu(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat, uint32_t serial, int32_t x, int32_t y) {}
static void toplevel_move(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat, uint32_t serial) {}
static void toplevel_resize(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat, uint32_t serial, uint32_t edges) {}
static void toplevel_size(struct wl_client *c, struct wl_resource *r, int32_t w, int32_t h) {}
static void toplevel_noarg(struct wl_client *c, struct wl_resource *r) {}
static void toplevel_output(struct wl_client *c, struct wl_resource *r, struct wl_resource *o) {}
static const struct xdg_toplevel_interface toplevel_impl = {
	toplevel_destroy, toplevel_parent, toplevel_string, toplevel_string, toplevel_menu, toplevel_move,
	toplevel_resize, toplevel_size, toplevel_size, toplevel_noarg, toplevel_noarg, toplevel_output,
	toplevel_noarg, toplevel_noarg,
};

static void xdg_surface_destroy_req(struct wl_client *c, struct wl_resource *r) { wl_resource_destroy(r); }
static void xdg_surface_get_toplevel(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
	struct wl_resource *t = wl_resource_create(c, &xdg_toplevel_interface, wl_resource_get_version(r), id);
	wl_resource_set_implementation(t, &toplevel_impl, NULL, NULL);
	struct wl_array states;
	wl_array_init(&states);
	xdg_toplevel_send_configure(t, 640, 400, &states);
	xdg_surface_send_configure(r, 1);
}
static void xdg_surface_get_popup(struct wl_client *c, struct wl_resource *r, uint32_t id, struct wl_resource *p, struct wl_resource *pos) {}
static void xdg_surface_geometry(struct wl_client *c, struct wl_resource *r, int32_t x, int32_t y, int32_t w, int32_t h) {}
static void xdg_surface_ack(struct wl_client *c, struct wl_resource *r, uint32_t serial) {}
static const struct xdg_surface_interface xdg_surface_impl = {
	xdg_surface_destroy_req, xdg_surface_get_toplevel, xdg_surface_get_popup, xdg_surface_geometry, xdg_surface_ack,
};

static void wm_destroy(struct wl_client *c, struct wl_resource *r) { wl_resource_destroy(r); }
static void wm_positioner(struct wl_client *c, struct wl_resource *r, uint32_t id) {}
static void wm_get_xdg_surface(struct wl_client *c, struct wl_resource *r, uint32_t id, struct wl_resource *surface)
{
	surface_res = surface;
	struct wl_resource *x = wl_resource_create(c, &xdg_surface_interface, wl_resource_get_version(r), id);
	wl_resource_set_implementation(x, &xdg_surface_impl, NULL, NULL);
}
static void wm_pong(struct wl_client *c, struct wl_resource *r, uint32_t serial) {}
static const struct xdg_wm_base_interface wm_impl = { wm_destroy, wm_positioner, wm_get_xdg_surface, wm_pong };
static void wm_bind(struct wl_client *c, void *d, uint32_t v, uint32_t id)
{
	struct wl_resource *r = wl_resource_create(c, &xdg_wm_base_interface, v, id);
	wl_resource_set_implementation(r, &wm_impl, NULL, NULL);
}

static void seat_device(struct wl_client *c, struct wl_resource *r, uint32_t id) {}
static void seat_release(struct wl_client *c, struct wl_resource *r) { wl_resource_destroy(r); }
static const struct wl_seat_interface seat_impl = { seat_device, seat_device, seat_device, seat_release };
static void seat_bind(struct wl_client *c, void *d, uint32_t v, uint32_t id)
{
	struct wl_resource *r = wl_resource_create(c, &wl_seat_interface, v, id);
	wl_resource_set_implementation(r, &seat_impl, NULL, NULL);
	wl_seat_send_capabilities(r, 0);
}

static void ti_destroy(struct wl_client *c, struct wl_resource *r) { wl_resource_destroy(r); }
static void ti_enable(struct wl_client *c, struct wl_resource *r) { fprintf(stderr, "FAKE client enable\n"); }
static void ti_disable(struct wl_client *c, struct wl_resource *r) { fprintf(stderr, "FAKE client disable\n"); }
static void ti_surrounding(struct wl_client *c, struct wl_resource *r, const char *t, int32_t a, int32_t b) {}
static void ti_cause(struct wl_client *c, struct wl_resource *r, uint32_t cause) {}
static void ti_content(struct wl_client *c, struct wl_resource *r, uint32_t hint, uint32_t purpose)
{
	fprintf(stderr, "FAKE client content_type hint=%u purpose=%u\n", hint, purpose);
}
static void ti_rect(struct wl_client *c, struct wl_resource *r, int32_t x, int32_t y, int32_t w, int32_t h)
{
	fprintf(stderr, "FAKE client cursor_rect %d,%d %dx%d\n", x, y, w, h);
}
static void ti_commit(struct wl_client *c, struct wl_resource *r)
{
	commits++;
	fprintf(stderr, "FAKE client commit %u\n", commits);
}
static const struct zwp_text_input_v3_interface ti_impl = {
	ti_destroy, ti_enable, ti_disable, ti_surrounding, ti_cause, ti_content, ti_rect, ti_commit,
};
static void tim_destroy(struct wl_client *c, struct wl_resource *r) { wl_resource_destroy(r); }
static void tim_get_text_input(struct wl_client *c, struct wl_resource *r, uint32_t id, struct wl_resource *seat)
{
	text_input_res = wl_resource_create(c, &zwp_text_input_v3_interface, wl_resource_get_version(r), id);
	wl_resource_set_implementation(text_input_res, &ti_impl, NULL, NULL);
	wl_event_source_timer_update(timer, 2500);
}
static const struct zwp_text_input_manager_v3_interface tim_impl = { tim_destroy, tim_get_text_input };
static void tim_bind(struct wl_client *c, void *d, uint32_t v, uint32_t id)
{
	struct wl_resource *r = wl_resource_create(c, &zwp_text_input_manager_v3_interface, v, id);
	wl_resource_set_implementation(r, &tim_impl, NULL, NULL);
}

int main(int argc, char **argv)
{
	if (argc != 4) {
		fprintf(stderr, "usage: compositor ime|die|no-abgr SOCKET DUMP_DIR\n");
		return 2;
	}
	scenario = argv[1];
	dump_dir = argv[3];
	display = wl_display_create();
	loop = wl_display_get_event_loop(display);
	timer = wl_event_loop_add_timer(loop, tick, NULL);
	if (wl_display_add_socket(display, argv[2]) != 0) {
		fprintf(stderr, "FAKE cannot add socket\n");
		return 1;
	}
	wl_display_init_shm(display);
	if (strcmp(scenario, "no-abgr") != 0)
		wl_display_add_shm_format(display, WL_SHM_FORMAT_ABGR8888);
	wl_global_create(display, &wl_compositor_interface, 4, NULL, compositor_bind);
	wl_global_create(display, &xdg_wm_base_interface, 6, NULL, wm_bind);
	wl_global_create(display, &wl_seat_interface, 9, NULL, seat_bind);
	wl_global_create(display, &zwp_text_input_manager_v3_interface, 1, NULL, tim_bind);
	if (strcmp(scenario, "die") == 0)
		wl_event_source_timer_update(timer, 3000);
	if (strcmp(scenario, "no-abgr") == 0)
		wl_event_source_timer_update(timer, 4000);
	fprintf(stderr, "FAKE ready\n");
	wl_display_run(display);
	wl_display_destroy(display);
	return 0;
}
