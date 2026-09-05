#include <adwaita.h>
#include <glib-unix.h>

#ifdef __linux__
#include <gdk/x11/gdkx.h>
#include <gdk/wayland/gdkwayland.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <libnotify/notify.h>
#include <canberra.h>
#endif

#include <ghostty.h>
