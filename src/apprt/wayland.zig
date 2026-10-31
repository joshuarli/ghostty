pub const App = @import("wayland/App.zig");
pub const Surface = @import("wayland/Surface.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("wayland/clipboard.zig");
    _ = @import("wayland/connection.zig");
    _ = @import("wayland/key_repeat.zig");
    _ = @import("wayland/seat.zig");
    _ = @import("wayland/window.zig");
}
