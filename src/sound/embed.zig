const file = @embedFile("assets/buckling-spring.rvpack");

pub const pack: [file.len]u8 align(16) = file.*;
