-- Theme "next": the grey of NeXTSTEP and classic Window Maker.
-- Thick, square frames, tight gaps, the light-and-dark bevel everywhere.
--
-- Install:  mkdir -p ~/.config/wmaker-wl/Themes && cp next.lua ~/.config/wmaker-wl/Themes/
-- Use:      theme("next")        (in ~/.config/wmaker-wl/config.lua), then reload
--
-- A theme sets how things LOOK and nothing else: any other option in the file
-- is ignored with a warning, so a theme you download can never bind a key or
-- start a program.

-- windows
border_width     = 3
border_focused   = "#e8e8e8"
border_unfocused = "#6a6a72"
border_floating  = "#8a8aa8"
gap              = 4
outer_gap        = 4

-- Dock, Clip, Drawers
tile_from        = "#c6c2c6"
tile_to          = "#9a969a"
tile_hot_from    = "#dedade"
tile_hot_to      = "#aeaaae"
logo_from        = "#5a5a62"
logo_to          = "#1e1e24"
logo_text        = "#ffffff"
tile_text        = "#000000"
bevel_light      = "#ffffff"
bevel_dark       = "#555555"
arrow            = "#303030"
arrow_hot        = "#ffffff"

-- fonts
font_dock_logo   = "Sans Bold 22"
font_dock_number = "Sans Bold 20"
