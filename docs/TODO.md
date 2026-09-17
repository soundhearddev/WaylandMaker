## TODO SOON!

- [ ] Fix keybind, Mod+4 input and declare default keybinds.


## TODO

- [x] Set up the Zig build script (`build.zig`) with Wayland and River client dependencies.

- [x] Initialize the Wayland display, event loop, and registry bindings for River components.

- [x] Establish a connection to the `river_window_manager_v1` protocol.

- [x] Integrate XDG-Shell / River window event listeners for window management.

- [x] Integrate output management (`river_output_v1`) to detect screen coordinates and dimensions.

- [x] Integrate input devices (`river_seat_v1` / `river_xkb_bindings_v1`) for keyboard and mouse interactions.

- [ ] Complete focus handling and event forwarding for active windows (`river_seat.focusWindow`).

- [x] Implement data structures for windows, columns, strips, and workspaces (`types.zig`).

- [ ] Refine the layout engine for scrollable tiling (Strip → Column → Window, niri-style).

- [ ] Implement mouse interactions (move, resize) and workspace visibility.

- [ ] Integrate window titles and title bars inspired by the classic Window Maker look and feel.

- [ ] Add configuration (ZON or another structured format) for keybindings and layout parameters.

- [ ] Perform stability testing, memory management (GPA), and performance optimizations in Zig.