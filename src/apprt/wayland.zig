pub const App = @import("wayland/App.zig");
pub const Surface = @import("wayland/Surface.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());
}
