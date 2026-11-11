#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "mako.h"
#include "notification.h"
#include "wayland.h"

static inline int foxml_banner_header(struct mako_state *state, struct mako_surface *surface) {
    if (!(surface->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP)) return 0;
    struct mako_notification *n;
    bool paper = false;
    wl_list_for_each(n, &state->notifications, link)
        if (n->surface == surface && !n->style.invisible && n->style.foxml_paper_shape == 1) paper = true;
    if (!paper) return 0;
    const char *path = getenv("FOXML_MAKO_BAR_GEOMETRY");
    FILE *f = path ? fopen(path, "r") : NULL;
    int height = 66;
    if (f) {
        char name[256]; int candidate;
        while (fscanf(f, "%255s %d", name, &candidate) == 2)
            if (surface->surface_output && surface->surface_output->name &&
                strcmp(name, surface->surface_output->name) == 0 && candidate >= 32 && candidate <= 256) height = candidate;
        fclose(f);
    }
    return height;
}

// A change-only runtime signal lets the existing bar stay in front while a
// ribbon is present. No polling, new process or persistent user configuration.
static inline void foxml_publish_banner(struct mako_state *state, bool clear) {
    static char previous[4096] = "unpublished";
    const char *path = getenv("FOXML_MAKO_BANNER_STATE");
    if (!path || !*path) return;
    char names[4096] = "";
    if (!clear) {
        struct mako_surface *s;
        wl_list_for_each(s, &state->surfaces, link) {
            if (s->surface_output && s->surface_output->name && foxml_banner_header(state, s)) {
                size_t used = strlen(names), len = strlen(s->surface_output->name);
                if (used + len + 2 < sizeof(names)) { memcpy(names + used, s->surface_output->name, len); names[used + len] = '\n'; }
            }
        }
    }
    if (strcmp(names, previous) == 0) return;
    char *tmp = malloc(strlen(path) + 16);
    if (!tmp) return;
    sprintf(tmp, "%s.XXXXXX", path);
    int fd = mkstemp(tmp);
    if (fd >= 0) {
        FILE *f = fdopen(fd, "w");
        if (f) {
            bool ok = fputs(names, f) >= 0;
            if (fclose(f) != 0) ok = false;
            if (ok && rename(tmp, path) == 0) strcpy(previous, names);
        } else close(fd);
        unlink(tmp);
    }
    free(tmp);
}
