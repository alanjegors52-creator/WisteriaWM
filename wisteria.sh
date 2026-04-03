#!/bin/bash
set -e

# 1. Setup Directories
CONF_DIR="$HOME/.config/wisteria"
CONF_FILE="$CONF_DIR/wisteria.conf"
mkdir -p "$CONF_DIR"

# 2. Auto-Generate Hypr-style Config
if [ ! -f "$CONF_FILE" ]; then
    echo "creating config at $CONF_FILE..."
    cat > "$CONF_FILE" << 'EOF'
# Wisteria Configuration (Hyprland Style)

# --- AUTOSTART ---
exec-once = xsetroot -solid "#282a36"

# --- KEYBINDS ---
bind = MOD+Return, exec, kitty
bind = MOD+d, exec, dmenu_run
bind = MOD+f, toggle_fullscreen
bind = MOD+space, toggle_canvas
bind = MOD+q, kill_window
bind = MOD+Shift+R, reload_config
EOF
fi

# 3. Write and Compile C Engine
mkdir -p ~/wisteria && cd ~/wisteria
cat > wisteria.c << 'EOF'
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdbool.h>

#define MOD Mod4Mask
#define GAP 10
#define BORDER 2
#define FOCUS_COLOR 0xbb86fc
#define UNFOCUS_COLOR 0x2e2e2e
#define EDGE_SENSITIVITY 10
#define EDGE_SPEED 8

typedef struct Node {
    Window win;
    struct Node *parent, *left, *right;
    int x, y, w, h;
    int wx, wy;
    bool is_split, split_vert; 
    bool is_fullscreen;
} Node;

typedef struct {
    KeySym ks;
    unsigned int mask;
    char action[32];
    char cmd[256];
} Binding;

Display *dpy;
Window root;
int sw, sh;
Node *tree = NULL, *focused = NULL, *active_node = NULL;
Binding binds[64];
int bind_count = 0;

bool canvas_mode = false;
bool is_panning = false, is_moving = false, is_resizing = false;
double cam_x = 0, cam_y = 0, zoom = 1.0;
int start_mouse_x, start_mouse_y;
double start_cam_x, start_cam_y;
int start_win_x, start_win_y, start_win_w, start_win_h;

Atom net_wm_name, net_supporting_wm_check, net_supported, utf8_string;

int xerror(Display *dpy, XErrorEvent *ee) { return 0; }

void setup_ewmh() {
    net_wm_name = XInternAtom(dpy, "_NET_WM_NAME", False);
    net_supporting_wm_check = XInternAtom(dpy, "_NET_SUPPORTING_WM_CHECK", False);
    net_supported = XInternAtom(dpy, "_NET_SUPPORTED", False);
    utf8_string = XInternAtom(dpy, "UTF8_STRING", False);

    Window wm_win = XCreateSimpleWindow(dpy, root, 0, 0, 1, 1, 0, 0, 0);
    XChangeProperty(dpy, wm_win, net_wm_name, utf8_string, 8, PropModeReplace, (unsigned char *)"Wisteria", 8);
    XChangeProperty(dpy, wm_win, net_supporting_wm_check, XA_WINDOW, 32, PropModeReplace, (unsigned char *)&wm_win, 1);
    XChangeProperty(dpy, root, net_supporting_wm_check, XA_WINDOW, 32, PropModeReplace, (unsigned char *)&wm_win, 1);

    Atom supported[] = { net_wm_name, net_supporting_wm_check, net_supported };
    XChangeProperty(dpy, root, net_supported, XA_ATOM, 32, PropModeReplace, (unsigned char *)supported, 3);
}

Node* find_node(Node *n, Window w) {
    if (!n) return NULL;
    if (n->win == w) return n;
    Node *res = find_node(n->left, w);
    return res ? res : find_node(n->right, w);
}

void apply_layout(Node *n, int x, int y, int w, int h) {
    if (!n) return;
    if (n->is_fullscreen && !n->is_split) {
        XSetWindowBorderWidth(dpy, n->win, 0);
        XMoveResizeWindow(dpy, n->win, 0, 0, sw, sh);
        XRaiseWindow(dpy, n->win);
        return;
    }
    if (!n->is_split) XSetWindowBorderWidth(dpy, n->win, BORDER);
    if (canvas_mode) {
        if (!n->is_split) {
            int mid_x = sw / 2, mid_y = sh / 2;
            int sx = (int)((n->wx - cam_x) * zoom + mid_x);
            int sy = (int)((n->wy - cam_y) * zoom + mid_y);
            int zw = (int)(n->w * zoom);
            int zh = (int)(n->h * zoom);
            if (zw < 50) zw = 50; 
            if (zh < 50) zh = 50;
            XMoveResizeWindow(dpy, n->win, sx, sy, zw, zh);
        } else {
            apply_layout(n->left, 0, 0, 0, 0);
            apply_layout(n->right, 0, 0, 0, 0);
        }
        return;
    }
    n->x = x; n->y = y;
    if (!n->is_split) {
        n->w = w - 2*GAP; n->h = h - 2*GAP;
        n->wx = x + GAP - (sw / 2); n->wy = y + GAP - (sh / 2);
        XMoveResizeWindow(dpy, n->win, x + GAP, y + GAP, n->w - 2*BORDER, n->h - 2*BORDER);
    } else {
        if (n->split_vert) {
            apply_layout(n->left, x, y, w / 2, h);
            apply_layout(n->right, x + w / 2, y, w / 2, h);
        } else {
            apply_layout(n->left, x, y, w, h / 2);
            apply_layout(n->right, x, y + h / 2, w, h / 2);
        }
    }
}

void load_config() {
    char path[256], line[512];
    snprintf(path, sizeof(path), "%s/.config/wisteria/wisteria.conf", getenv("HOME"));
    FILE *f = fopen(path, "r");
    bind_count = 0;
    XUngrabKey(dpy, AnyKey, AnyModifier, root);
    if (!f) return;
    while (fgets(line, sizeof(line), f) && bind_count < 64) {
        if (line[0] == '#' || strlen(line) < 5) continue;
        if (strncmp(line, "exec-once =", 11) == 0) {
            if (fork() == 0) { setsid(); system(line + 11); exit(0); }
        } else if (strncmp(line, "bind =", 6) == 0) {
            char *content = strdup(line + 6), *key_p = strtok(content, ","), *act_p = strtok(NULL, ","), *cmd_p = strtok(NULL, "\n");
            if (key_p && act_p) {
                binds[bind_count].mask = 0;
                if (strstr(key_p, "MOD")) binds[bind_count].mask |= MOD;
                if (strstr(key_p, "Shift")) binds[bind_count].mask |= ShiftMask;
                char *k_name = strrchr(key_p, '+'); k_name = k_name ? k_name + 1 : key_p;
                while (*k_name == ' ') k_name++;
                binds[bind_count].ks = (strstr(k_name, "Return")) ? XK_Return : XStringToKeysym(k_name);
                strncpy(binds[bind_count].action, act_p + 1, 31);
                if (cmd_p) strncpy(binds[bind_count].cmd, cmd_p + 1, 255);
                XGrabKey(dpy, XKeysymToKeycode(dpy, binds[bind_count].ks), binds[bind_count].mask, root, True, GrabModeAsync, GrabModeAsync);
                bind_count++;
            }
            free(content);
        }
    }
    fclose(f);
}

void focus_node(Node *n) {
    if (!n || n->win == None) return;
    if (focused && focused->win != None) XSetWindowBorder(dpy, focused->win, UNFOCUS_COLOR);
    focused = n;
    XSetWindowBorder(dpy, n->win, FOCUS_COLOR);
    XSetInputFocus(dpy, n->win, RevertToPointerRoot, CurrentTime);
    XRaiseWindow(dpy, n->win);
}

void add_window(Window w) {
    XWindowAttributes wa; XGetWindowAttributes(dpy, w, &wa);
    if (wa.override_redirect || find_node(tree, w)) return;
    Node *new_node = calloc(1, sizeof(Node));
    new_node->win = w;
    if (canvas_mode) {
        Window r, c; int rx, ry, wx, wy; unsigned int m;
        XQueryPointer(dpy, root, &r, &c, &rx, &ry, &wx, &wy, &m);
        new_node->wx = (int)((rx - (sw/2)) / zoom + cam_x);
        new_node->wy = (int)((ry - (sh/2)) / zoom + cam_y);
        new_node->w = 800; new_node->h = 600;
    }
    if (!tree) tree = new_node;
    else {
        Node *target = (focused && !focused->is_split) ? focused : tree;
        while(target->is_split) target = target->right;
        Node *parent = calloc(1, sizeof(Node));
        parent->parent = target->parent; parent->is_split = true;
        parent->split_vert = (target->w >= target->h);
        if (target->parent) {
            if (target->parent->left == target) target->parent->left = parent;
            else target->parent->right = parent;
        } else tree = parent;
        target->parent = parent; new_node->parent = parent;
        parent->left = target; parent->right = new_node;
    }
    XSelectInput(dpy, w, StructureNotifyMask | EnterWindowMask);
    XSetWindowBorderWidth(dpy, w, BORDER);
    XMapWindow(dpy, w);
    apply_layout(tree, 0, 0, sw, sh);
    focus_node(new_node);
}

void remove_window(Window w) {
    Node *n = find_node(tree, w);
    if (!n) return;
    if (n->parent) {
        Node *p = n->parent;
        Node *sib = (p->left == n) ? p->right : p->left;
        sib->parent = p->parent;
        if (!p->parent) tree = sib;
        else { if (p->parent->left == p) p->parent->left = sib; else p->parent->right = sib; }
        if (focused == n) focus_node(sib);
        free(p);
    } else { tree = NULL; focused = NULL; }
    free(n);
    apply_layout(tree, 0, 0, sw, sh);
}

int main() {
    if (!(dpy = XOpenDisplay(NULL))) return 1;
    XSetErrorHandler(xerror);
    root = DefaultRootWindow(dpy);
    XStoreName(dpy, root, "Wisteria");
    sw = DisplayWidth(dpy, 0); sh = DisplayHeight(dpy, 0);
    
    setup_ewmh();
    
    XSelectInput(dpy, root, SubstructureRedirectMask|SubstructureNotifyMask|KeyPressMask|PointerMotionMask|ButtonPressMask|ButtonReleaseMask);
    load_config();
    XGrabButton(dpy, 1, AnyModifier, root, True, ButtonPressMask|ButtonReleaseMask|PointerMotionMask, GrabModeAsync, GrabModeAsync, None, None);
    XGrabButton(dpy, 3, MOD, root, True, ButtonPressMask|ButtonReleaseMask|PointerMotionMask, GrabModeAsync, GrabModeAsync, None, None);
    XGrabButton(dpy, 4, MOD, root, True, ButtonPressMask, GrabModeAsync, GrabModeAsync, None, None);
    XGrabButton(dpy, 5, MOD, root, True, ButtonPressMask, GrabModeAsync, GrabModeAsync, None, None);

    XEvent ev;
    while (1) {
        XNextEvent(dpy, &ev);
        if (ev.type == MapRequest) add_window(ev.xmaprequest.window);
        if (ev.type == DestroyNotify || ev.type == UnmapNotify) remove_window(ev.xany.window);
        if (ev.type == EnterNotify) { Node *n = find_node(tree, ev.xcrossing.window); if (n) focus_node(n); }
        if (ev.type == KeyPress) {
            KeySym ks = XLookupKeysym(&ev.xkey, 0);
            for (int i=0; i<bind_count; i++) {
                if (binds[i].ks == ks && (ev.xkey.state & binds[i].mask) == binds[i].mask) {
                    if (strstr(binds[i].action, "exec")) { if(fork()==0){setsid();system(binds[i].cmd);exit(0);} }
                    else if (strstr(binds[i].action, "toggle_canvas")) { canvas_mode = !canvas_mode; if(!canvas_mode){cam_x=0;cam_y=0;zoom=1.0;} apply_layout(tree, 0, 0, sw, sh); }
                    else if (strstr(binds[i].action, "toggle_fullscreen") && focused) { focused->is_fullscreen = !focused->is_fullscreen; apply_layout(tree, 0, 0, sw, sh); }
                    else if (strstr(binds[i].action, "kill_window") && focused) { XKillClient(dpy, focused->win); }
                    else if (strstr(binds[i].action, "reload_config")) { load_config(); }
                }
            }
        }
        if (ev.type == ButtonPress) {
            Node *n = find_node(tree, ev.xbutton.subwindow);
            start_mouse_x = ev.xbutton.x_root; start_mouse_y = ev.xbutton.y_root;
            if (ev.xbutton.button == 1 && (ev.xbutton.state & MOD) && n) { is_moving = true; active_node = n; start_win_x = n->wx; start_win_y = n->wy; }
            else if (ev.xbutton.button == 3 && (ev.xbutton.state & MOD) && n) { is_resizing = true; active_node = n; start_win_w = n->w; start_win_h = n->h; }
            else if (ev.xbutton.button == 1 && canvas_mode && ev.xbutton.subwindow == None) { 
                is_panning = true; start_cam_x = cam_x; start_cam_y = cam_y;
            }
            else if (ev.xbutton.button == 4 && canvas_mode) { zoom *= 1.1; apply_layout(tree, 0, 0, sw, sh); }
            else if (ev.xbutton.button == 5 && canvas_mode) { zoom /= 1.1; apply_layout(tree, 0, 0, sw, sh); }
        }
        if (ev.type == ButtonRelease) is_panning = is_moving = is_resizing = false;
        if (ev.type == MotionNotify) {
            int mx = ev.xmotion.x_root, my = ev.xmotion.y_root;
            int dx = mx - start_mouse_x, dy = my - start_mouse_y;
            if (canvas_mode) {
                bool pushed = false;
                if (mx < EDGE_SENSITIVITY) { cam_x -= EDGE_SPEED / zoom; pushed = true; }
                if (mx > sw - EDGE_SENSITIVITY) { cam_x += EDGE_SPEED / zoom; pushed = true; }
                if (my < EDGE_SENSITIVITY) { cam_y -= EDGE_SPEED / zoom; pushed = true; }
                if (my > sh - EDGE_SENSITIVITY) { cam_y += EDGE_SPEED / zoom; pushed = true; }
                if (pushed) apply_layout(tree, 0, 0, sw, sh);
            }
            if (is_panning) { cam_x = start_cam_x - dx / zoom; cam_y = start_cam_y - dy / zoom; }
            else if (is_moving && active_node) { active_node->wx = start_win_x + dx / zoom; active_node->wy = start_win_y + dy / zoom; }
            else if (is_resizing && active_node) { active_node->w = start_win_w + dx / zoom; active_node->h = start_win_h + dy / zoom; }
            apply_layout(tree, 0, 0, sw, sh);
        }
    }
    return 0;
}
EOF

gcc -Wall -O2 wisteria.c -o wisteria -lX11
sudo cp wisteria /usr/local/bin/
echo "Wisteria wm v1.0 installed gang :3"
echo "also either you're me or a friend, so thanks"