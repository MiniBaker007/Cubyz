const std = @import("std");

const main = @import("main");

const c = @cImport({
	@cDefine("_BITS_STDIO2_H", ""); // TODO: Zig fails to include this header file
	@cInclude("miniaudio.h");
});

fn handleError(miniaudioError: c.ma_result) !void {
	if(miniaudioError != c.MA_SUCCESS) {
		std.log.err("miniaudio error: {s}", .{c.ma_result_description(miniaudioError)});
		return error.miniaudioError;
	}
}

fn onLog(pUserData: ?*anyopaque, logLevel: c.ma_uint32, pMessage: [*c]const u8) callconv(.c) void {
	_ = pUserData;
	const message = std.mem.sliceTo(pMessage, 0);

	switch(logLevel) {
		c.MA_LOG_LEVEL_DEBUG => std.log.debug("miniaudio: {s}", .{message}),
		c.MA_LOG_LEVEL_INFO => std.log.info("miniaudio: {s}", .{message}),
		c.MA_LOG_LEVEL_WARNING => std.log.warn("miniaudio: {s}", .{message}),
		c.MA_LOG_LEVEL_ERROR => std.log.err("miniaudio: {s}", .{message}),
		else => std.log.info("miniaudio: {s}", .{message}),
	}
}

const fadeDurationMs: c.ma_uint64 = 5000;

const Music = struct {
	id: []const u8,
	sound: c.ma_sound,

	fn init(self: *Music, musicId: []const u8) !void {
		const colonIndex = std.mem.indexOfScalar(u8, musicId, ':') orelse {
			std.log.err("Invalid music id: {s}. Must be of the form 'addon:file_name'", .{musicId});
			return;
		};
		const addon = musicId[0..colonIndex];
		const fileName = musicId[colonIndex + 1 ..];

		const path1 = std.fmt.allocPrintSentinel(main.stackAllocator.allocator, "assets/{s}/music/{s}.ogg", .{addon, fileName}, 0) catch unreachable;
		defer main.stackAllocator.free(path1);

		const flags = c.MA_SOUND_FLAG_STREAM | c.MA_SOUND_FLAG_ASYNC | c.MA_SOUND_FLAG_LOOPING | c.MA_SOUND_FLAG_NO_PITCH | c.MA_SOUND_FLAG_NO_SPATIALIZATION;
		handleError(c.ma_sound_init_from_file(&engine, path1, flags, null, null, &self.sound)) catch {
			const path2 = std.fmt.allocPrintSentinel(main.stackAllocator.allocator, "{s}/serverAssets/{s}/music/{s}.ogg", .{main.files.cubyzDirStr(), addon, fileName}, 0) catch unreachable;
			defer main.stackAllocator.free(path2);

			try handleError(c.ma_sound_init_from_file(&engine, path2, flags, null, null, &self.sound));
		};

		self.id = main.globalAllocator.dupe(u8, musicId);
	}

	fn deinit(self: *Music) void {
		main.globalAllocator.free(self.id);
		self.id = "";
		c.ma_sound_uninit(&self.sound);
	}

	fn start(self: *Music) void {
		handleError(c.ma_sound_start(&self.sound)) catch {
			std.log.err("Could not start music: {s}", .{self.id});
			return;
		};
		c.ma_sound_set_fade_in_milliseconds(&self.sound, 0, 1, fadeDurationMs);
	}

	fn isInit(self: *const Music) bool {
		return self.id.len != 0;
	}

	fn isFadingOut(self: *const Music) bool {
		const fader = self.sound.engineNode.fader;
		return fader.volume() > fader.volumeEnd;
	}
};

var currentMusic: *Music = undefined;
var nextMusic: *Music = undefined;

var engine: c.ma_engine = undefined;
var resourceManager: c.ma_resource_manager = undefined;
var log: c.ma_log = undefined;

var mutex: std.Thread.Mutex = .{};

pub fn init() !void {
	try handleError(c.ma_log_init(null, &log));
	const logCallback = c.ma_log_callback_init(onLog, null);
	try handleError(c.ma_log_register_callback(&log, logCallback));

	var resourceManagerConfig = c.ma_resource_manager_config_init();
	resourceManagerConfig.pLog = &log;
	try handleError(c.ma_resource_manager_init(&resourceManagerConfig, &resourceManager));

	var engineConfig = c.ma_engine_config_init();
	engineConfig.pLog = &log;
	engineConfig.pResourceManager = &resourceManager;
	try handleError(c.ma_engine_init(&engineConfig, &engine));

	currentMusic = main.globalAllocator.create(Music);
	nextMusic = main.globalAllocator.create(Music);
}

pub fn deinit() void {
	mutex.lock();
	defer mutex.unlock();

	if(currentMusic.isInit()) {
		currentMusic.deinit();
		main.globalAllocator.destroy(currentMusic);
	}
	if(nextMusic.isInit()) {
		nextMusic.deinit();
		main.globalAllocator.destroy(nextMusic);
	}

	c.ma_engine_uninit(&engine);
	c.ma_resource_manager_uninit(&resourceManager);
	c.ma_log_uninit(&log);
}

pub fn update() void {
	handleError(c.ma_engine_set_volume(&engine, main.settings.musicVolume)) catch {
		std.log.err("Failed to set volume.", .{});
	};

	if(nextMusic.isInit() and c.ma_sound_is_playing(&currentMusic.sound) == c.MA_FALSE) {
		mutex.lock();
		defer mutex.unlock();

		currentMusic.deinit();

		const tmp = currentMusic;
		currentMusic = nextMusic;
		nextMusic = tmp;

		currentMusic.start();
	}
}

pub fn setMusic(musicId: []const u8) void {
	if(musicId.len == 0) return;

	mutex.lock();
	defer mutex.unlock();

	if(!currentMusic.isInit()) {
		currentMusic.init(musicId) catch {
			std.log.err("Failed to load music: {s}", .{musicId});
			return;
		};
		currentMusic.start();
		return;
	}

	if(std.mem.eql(u8, musicId, currentMusic.id)) {
		if(currentMusic.isFadingOut()) {
			c.ma_sound_set_fade_in_milliseconds(&currentMusic.sound, -1, 1, fadeDurationMs);
			c.ma_sound_set_stop_time_in_pcm_frames(&currentMusic.sound, std.math.maxInt(u64));
		}
		return;
	}

	if(std.mem.eql(u8, musicId, nextMusic.id)) {
		if(!currentMusic.isFadingOut()) {
			_ = c.ma_sound_stop_with_fade_in_milliseconds(&currentMusic.sound, fadeDurationMs);
		}
		return;
	}

	if(nextMusic.isInit()) nextMusic.deinit();
	nextMusic.init(musicId) catch {
		std.log.err("Failed to load music: {s}", .{musicId});
		return;
	};
	_ = c.ma_sound_stop_with_fade_in_milliseconds(&currentMusic.sound, fadeDurationMs);
}
