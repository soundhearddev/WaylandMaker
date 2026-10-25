-- wmaker-wl default configuration.
--
-- This is a Lua script. Copy it to ~/.config/wmaker-wl/config.lua and edit.
-- Anything you do not set keeps the value below. Options are plain variables
-- (`gap = 8`); `bind("Super+x", "close")` replaces a default bind on the same
-- key combination, `unbind("Super+q")` removes one. Colours are "#rrggbb"
-- strings or numbers (0xd8a657). A program is a string ("foot -e htop") or a
-- list ({ "foot", "-e", "htop" }). It is a real script, so loops and
-- `local` helpers work too; see the end of this file for an example.

-- ---- layout -----------------------------------------------------------------
gap = 8                          -- between windows
outer_gap = 8                    -- between windows and the screen edge
default_column_width = 0.5       -- fraction of the usable width
width_presets = { 0.333, 0.5, 0.667, 1.0 }
width_step = 0.1
min_window_size = 120
center_focused_column = "on_overflow"   -- on_overflow | always | never
new_window = "new_column"               -- new_column | stack
focus_new_windows = true         -- a new window takes the keyboard focus (false: opens in the background)
-- ---- external monitors ------------------------------------------------------
output_order = "position"        -- position (left to right) | connection: order of focus_output_next/prev
monitor_settle_ms = 400          -- a change of the monitors counts after this many ms without another one
-- A monitor is named by its connector ("DP-1"), by "make model" or by a part
-- of its description; "*" means every monitor. The most specific rule wins.
--   monitor("DP-1", { primary = true, workspaces = 6, start_workspace = 1 })
--   monitor("eDP-1", { enabled = false })              -- ignore the laptop screen
--   monitor("*", { on_connect = "notify-send 'monitor connected'" })
-- Windows taken off a monitor that went away return when it comes back
-- (restore_windows = false turns that off). wmaker-wl does not set modes or positions
-- yet: a profile runs the tool that does
-- (kanshi, wlr-randr) when exactly this set of monitors is connected:
--   monitor_profile{ name = "docked", needs = { "eDP-1", "DP-1" },
--                    run = "kanshictl switch docked" }

-- ---- space and view -----------------------------------------------------------
strut_left = 0                   -- extra space kept free on each side of the work area
strut_right = 0
strut_top = 0
strut_bottom = 0
center_single_column = false     -- a lone column that does not fill the screen sits in the middle
maximize_follow = true           -- the view stays locked on a maximized column (maximize_column)
maximize_keep_focus = false      -- a new tiled window does not take the focus from a maximized window

-- ---- animations ---------------------------------------------------------------
-- A spring is "spring DAMPING_RATIO STIFFNESS EPSILON" (ratio 0.1 .. 10, 1 = no
-- overshoot; stiffness >= 1; epsilon 0.00001 .. 0.1: where it counts as arrived).
-- An easing is "CURVE DURATION_MS" with CURVE = linear | ease-out-quad |
-- ease-out-cubic | ease-out-expo. "off" turns that one animation off.
animations = true                -- false: everything jumps
anim_slowdown = 1.0              -- 2.0 = everything runs at half speed, 0.5 = twice as fast
anim_window_movement = "spring 1.0 800 0.0001"   -- a tiled window moves (scroll, a column opens/closes/resizes)
anim_window_open = "ease-out-cubic 250"          -- a new window is uncovered from its middle (niri: "ease-out-expo 150", abrupt)

-- ---- look -------------------------------------------------------------------
border_width = 2
border_focused = "#d8a657"
border_unfocused = "#3c3836"
border_floating = "#7daea3"

-- ---- fonts --------------------------------------------------------------------
-- Pango font descriptions: "Family [Style] Size". Applied on the next reload.
font_menu_title = "Sans Bold 10"   -- title bar of a menu
font_menu = "Sans 10"              -- rows of a menu
font_dock = "Sans 8"               -- the workspace name in the Clip

-- ---- menus --------------------------------------------------------------------
menu_submenu_align = "right"       -- right | left: side of the parent a submenu opens on

-- ---- workspaces -------------------------------------------------------------
workspace_count = 4
workspace_wrap = true            -- workspace_next on the last one goes to the first
clip_scroll_workspaces = true    -- the mouse wheel over the Clip switches workspace
workspace_back_and_forth = false -- `workspace N` on the shown workspace goes back to the previous one
dynamic_workspaces = false       -- always one empty workspace at the end, empty ones behind it vanish
                                 -- (workspace_count is then the number that always exists)
-- Workspaces are modular: bind "workspace_add" / "workspace_remove_last" to grow and shrink the list
-- at run time, and `workspace 7` creates workspace 7 if it does not exist yet (up to 16).

-- ---- floating / mouse -------------------------------------------------------
drag_threshold = 24              -- px a tiled window is dragged before it floats
floating_size = 0.6              -- default size of a fresh floating window
mouse_mod = "Super"                -- Super+LMB moves, Super+RMB resizes
focus_follows_mouse = false
focus_follows_mouse_scroll = true -- with focus_follows_mouse: pointing at a window also scrolls the view to it
warp_mouse_to_focus = false      -- the pointer jumps into a window that got the focus by keyboard
prefer_no_csd = true             -- ask clients to leave out their own title bars

-- ---- programs ---------------------------------------------------------------
terminal = "alacritty"
launcher = "fuzzel"
browser = "firefox"

-- ---- WindowMaker compatibility (WMRootMenu, WMWindowAttributes, WMState) ------
enable_wmaker_compat = false

-- ---- startup -----------------------------------------------------------------
-- Programs started once at session start (not on a reload): a string is split
-- like a command line, a table is the argv.
--     spawn_at_startup = { "waybar", { "mako" }, "foot -e htop" }
-- Environment variables for every program wmaker-wl starts:
--     environment = { MOZ_ENABLE_WAYLAND = "1", QT_QPA_PLATFORM = "wayland" }
spawn_at_startup = {}
environment = {}

-- ---- session ------------------------------------------------------------------
-- Autostart works exactly like Window Maker's: on start, one shell script is
-- run once, detached. It is looked up first as ~/.config/wmaker-wl/autostart,
-- then (if enable_wmaker_compat = true) as ~/GNUstep/Library/WindowMaker/autostart.
-- The file does not need to exist, and does not need +x -- it always runs
-- through `/bin/sh`. Example ~/.config/wmaker-wl/autostart:
--
--     #!/bin/sh
--     nm-applet &
--     xrdb -merge ~/.Xresources &
--
enable_autostart = true

-- ---- dock apps ----------------------------------------------------------------
-- DockApps are programs that put themselves into the Dock (app_id
-- `dockapp:<name>`): start them from the autostart script above, from a menu
-- or by hand -- no list to maintain. Dock and Clip contents are Window
-- Maker's own WMState property list: wmaker-wl saves it itself in
-- $XDG_STATE_HOME/wmaker-wl/WMState and, if enable_wmaker_compat = true,
-- reads ~/GNUstep/Defaults/WMState (entries with `AutoLaunch = Yes` are
-- started once at session start). Neither file needs to exist.
enable_dockapps = true

-- ---- Themes and includes ------------------------------------------------------
-- `theme("NAME")` reads Themes/NAME.lua (next to this file, or in
-- /usr/share/wmaker-wl/Themes): colours, border width and gaps only -- a theme
-- runs with an empty environment, so it cannot bind a key or start a program.
-- Examples ship in share/Themes/.
-- `include("FILE")` runs any other file at that point (relative to this
-- file); lines after it override it, lines before it are overridden.
-- theme("nord")
-- include("local.lua")

-- ---- Keyboard ---------------------------------------------------------------
-- Bindings are translated with the layout that is active when a key is
-- pressed. To make `Super+q` mean the same physical key after switching between
-- layouts (e.g. us <-> de), pin them to one: 0 = the first layout of your
-- keyboard, 1 = the second, ... ("current" = follow the active layout.)
-- Keys can be written as characters: `bind("Super+ü", ...)`.
bind_layout = "current"

-- ---- Dock and Clip ----------------------------------------------------------
-- The Dock is Window Maker's column of tiles (dock_size, 64 px by default) on a screen edge (a logo
-- tile, then the entries of WMState). The Clip is
-- the tile with the workspace number and two arrows (upper right: next
-- workspace, lower left: previous), plus the Clip entries of the current
-- workspace. Both are drawn on the first output.
--
-- Precedence: wmaker-wl also remembers what you change with the mouse (move
-- the Dock/Clip, "Keep on Top", Collapsed, ...) in
-- $XDG_STATE_HOME/wmaker-wl/WMState. An option you write in YOUR config.lua
-- (dock_edge, dock_offset, dock_on_top, dock_auto_raise, clip_corner,
-- clip_on_top, clip_collapsed, clip_auto_collapse, clip_auto_raise) always
-- wins over that saved state. An option you leave out takes the saved value
-- (or the default below if nothing was saved yet). The lines below are only
-- the defaults: they do not count as "written by you".
dock_enabled = true
dock_size = 64                   -- px per tile (16..256); the icon inside is 3/4 of it
dock_edge = "right"                -- left | right
dock_offset = 0                  -- px from the top of the screen
dock_on_top = true               -- false: below the windows (the Dock menu changes it at run time)
dock_auto_raise = false          -- with dock_on_top = false: up while the pointer is on it
dock_reserve_space = true        -- keep tiled windows out from under the Dock
dock_single_click = false        -- launch with one click (default: double click, like Window Maker)
dock_save_state = true           -- remember moved/added/removed tiles
clip_enabled = true
clip_corner = "top_left"           -- top_left | top_right | bottom_left | bottom_right
clip_on_top = true
clip_collapsed = false           -- only the workspace tile, without its launchers
clip_auto_collapse = false       -- fold up when the pointer leaves, unfold when it returns
clip_auto_raise = false          -- with clip_on_top = false: up while the pointer is on it
mini_dock = true                 -- every minimized window gets a tile in the Dock (a click brings it back)
-- Names shown in the Clip and in the workspace menu, one per workspace, in
-- order. An empty entry means "no name". Without this line the names stored
-- in Window Maker's WMState are used (if enable_wmaker_compat is on).
-- workspace_names = { "Main", "Web", "Code", "Mail" }

-- ---- key bindings -----------------------------------------------------------
-- Syntax: bind("Mod+Mod+Key", "command [arguments]")
-- Key names are xkbcommon keysym names and follow your active layout.
--
-- `spawn <program> [args...]` splits its argument on whitespace (with
-- "double quoted" pieces) and execs it directly -- no shell involved, so
-- no $VARS, ~, pipes, or &&. Use it for a plain program + flags.
--
-- `shell <anything>` (aliases: `exec`, `shexec`) hands the rest of the
-- line to `/bin/sh -c` verbatim, exactly like the root menu's SHEXEC
-- entries and the autostart script. This is the general "run any command
-- on any key" escape hatch: pipes, &&/||, ~ and $VAR expansion, globs,
-- backgrounding with a trailing &, and chaining several programs on one
-- key all work, because the shell -- not wmaker-wl -- parses the line.
--
--     bind("Super+p", [[shell grim -g "$(slurp)" ~/Pictures/shot.png]])
--     bind("Super+l", "shell swaylock -f || pkill swaylock")
--     bind("Super+m", "shell playerctl play-pause &")
--     bind("Super+Shift+s", [[shell notify-send "$(date)" && pkill -RTMIN+8 waybar]])
--
-- (Lua long brackets [[ ... ]] need no escaping for the quotes inside.)

-- programs
bind("Super+Return", "spawn_terminal")
bind("Super+a", "spawn_launcher")
bind("Super+b", "spawn_browser")
bind("Super+p", [[shell grim -g "$(slurp)" ~/Pictures/shot-$(date +%s).png]])

-- session / window
bind("Super+q", "close")
bind("Super+Shift+e", "exit")
bind("Super+Shift+r", "reload_config")   -- re-read config.lua (same as pkill -HUP wmaker-wl)
bind("Super+t", "toggle_floating")
bind("Super+f", "toggle_fullscreen")
bind("Super+d", "maximize_column")   -- fills the work area, others are pushed aside
bind("Super+Shift+f", "maximize_column")

-- focus
bind("Super+h", "focus_left")
bind("Super+l", "focus_right")
bind("Super+j", "focus_down")
bind("Super+k", "focus_up")
bind("Super+Left", "focus_left")
bind("Super+Right", "focus_right")
bind("Super+Down", "focus_down")
bind("Super+Up", "focus_up")
bind("Super+Home", "focus_first_column")
bind("Super+End", "focus_last_column")
bind("Super+Tab", "focus_previous")
bind("Super+space", "focus_toggle_floating")

-- move
bind("Super+Shift+h", "move_column_left")
bind("Super+Shift+l", "move_column_right")
bind("Super+Shift+j", "move_window_down")
bind("Super+Shift+k", "move_window_up")
bind("Super+Shift+Left", "move_column_left")
bind("Super+Shift+Right", "move_column_right")
bind("Super+Shift+Down", "move_window_down")
bind("Super+Shift+Up", "move_window_up")
bind("Super+Shift+Home", "move_column_first")
bind("Super+Shift+End", "move_column_last")
bind("Super+comma", "consume_left")
bind("Super+period", "expel_right")

-- scrolling
bind("Super+bracketleft", "scroll_left")
bind("Super+bracketright", "scroll_right")
bind("Super+c", "center_column")

-- column width
bind("Super+r", "cycle_column_width")
bind("Super+minus", "narrow_column")
bind("Super+equal", "widen_column")

-- floating: nudge / resize with the keyboard
-- Minimize (Window Maker's miniaturize / hide). A minimized window leaves the
-- strip of columns, gets a tile (its application's icon) in the Dock and shows
-- in the Windows menu as (title); click the tile, choose it in the menu, or
-- press Super+Shift+n, to bring it back.
bind("Super+n", "minimize")
bind("Super+Shift+n", "restore")
bind("Super+Ctrl+n", "show_all")
bind("Super+o", "hide_others")
bind("Super+Shift+m", "toggle_mini_dock")    -- Dock tiles of minimized windows on / off

-- Several monitors: Super+Alt+Left/Right works on the previous/next output,
-- with Shift it takes the focused window along.
bind("Super+Alt+Left", "focus_output_prev")
bind("Super+Alt+Right", "focus_output_next")
bind("Super+Alt+Shift+Left", "move_to_output_prev")
bind("Super+Alt+Shift+Right", "move_to_output_next")

bind("Super+Ctrl+Left", "float_move -40 0")
bind("Super+Ctrl+Right", "float_move 40 0")
bind("Super+Ctrl+Up", "float_move 0 -40")
bind("Super+Ctrl+Down", "float_move 0 40")
bind("Super+Ctrl+Shift+Left", "float_resize -40 0")
bind("Super+Ctrl+Shift+Right", "float_resize 40 0")
bind("Super+Ctrl+Shift+Up", "float_resize 0 -40")
bind("Super+Ctrl+Shift+Down", "float_resize 0 40")

-- workspaces
bind("Super+1", "workspace 1")
bind("Super+2", "workspace 2")
bind("Super+3", "workspace 3")
bind("Super+4", "workspace 4")
bind("Super+Shift+1", "move_to_workspace 1")
bind("Super+Shift+2", "move_to_workspace 2")
bind("Super+Shift+3", "move_to_workspace 3")
bind("Super+Shift+4", "move_to_workspace 4")
bind("Super+Page_Down", "workspace_next")
bind("Super+Page_Up", "workspace_prev")
bind("Super+grave", "workspace_last")                       -- back to the previous workspace
bind("Super+Shift+Page_Down", "move_to_workspace_next")     -- takes the window along
bind("Super+Shift+Page_Up", "move_to_workspace_prev")
-- bind("Super+Ctrl+Page_Down", "workspace_add")            -- modular workspaces
-- bind("Super+Ctrl+Page_Up", "workspace_remove_last")
-- at the end of a column, go on to the next/previous workspace / output
-- bind("Super+Ctrl+j", "focus_window_or_workspace_down")
-- bind("Super+Ctrl+k", "focus_window_or_workspace_up")
-- bind("Super+Ctrl+h", "focus_column_or_output_left")
-- bind("Super+Ctrl+l", "focus_column_or_output_right")
-- bind("Super+Ctrl+r", "set_column_width 50%")

-- A loop instead of eight lines, if you want more workspaces:
-- workspace_count = 9
-- for i = 5, 9 do
--     bind("Super+" .. i, "workspace " .. i)
--     bind("Super+Shift+" .. i, "move_to_workspace " .. i)
-- end

-- ---- more Lua ------------------------------------------------------------------
-- Own variables are fine. Any name that is not an option is yours (an option
-- that is misspelt, like `gapp`, is reported with a suggestion):
--
--     local accent = "#d8a657"        -- `local` is the tidy way
--     my_term = "foot"                -- a global works as well
--     border_focused = accent
--
-- Every option can be read before you change it, so you can build on it:
--
--     gap = gap + 2
--     table.insert(width_presets, 0.25)
--     if os.getenv("HOSTNAME") == "laptop" then workspace_count = 2 end
--
-- A key can run a Lua function instead of a command. Inside it, run("...")
-- takes the same text as a bind (run("workspace 2")), spawn("foot -e htop")
-- starts a program and shell("a | b") runs a line through /bin/sh:
--
--     local n = 0
--     bind("Super+F5", function()
--         n = n + 1
--         if n % 2 == 1 then run("workspace 2") else run("workspace 1") end
--         shell("notify-send 'toggled " .. n .. " times'")
--     end)