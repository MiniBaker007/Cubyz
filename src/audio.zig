const std = @import("std");

const main = @import("main");

const c = @cImport({
	@cDefine("_BITS_STDIO2_H", ""); // TODO: Zig fails to include this header file
	@cInclude("miniaudio.h");
});

const File = struct {
	file: std.fs.File,
};

fn getFile(handle: c.ma_vfs_file) !*File {
	if(handle == null) return error.NullHandle;
	return @as(*File, @ptrCast(@alignCast(handle.?)));
}

fn vfsOnOpen(pVfs: ?*c.ma_vfs, pFilePath: [*c]const u8, openMode: c.ma_uint32, pFile: ?*c.ma_vfs_file) callconv(.c) c.ma_result {
	_ = pVfs;
	if(openMode != c.MA_OPEN_MODE_READ) {
		return c.MA_INVALID_ARGS;
	}
	if(pFile == null) {
		return c.MA_INVALID_ARGS;
	}

	const path = std.mem.sliceTo(pFilePath, 0);

	const vfsHandle = main.globalAllocator.create(File);

	vfsHandle.file = main.files.cwd().openFile(path) catch {
		main.globalAllocator.destroy(vfsHandle);
		return c.MA_DOES_NOT_EXIST;
	};

	pFile.?.* = vfsHandle;

	return c.MA_SUCCESS;
}

fn vfsOnClose(pVfs: ?*c.ma_vfs, pFile: c.ma_vfs_file) callconv(.c) c.ma_result {
	_ = pVfs;
	const vfsHandle = getFile(pFile) catch return c.MA_INVALID_ARGS;

	vfsHandle.file.close();
	main.globalAllocator.destroy(vfsHandle);
	return c.MA_SUCCESS;
}

fn vfsOnRead(pVfs: ?*c.ma_vfs, pFile: c.ma_vfs_file, pBuffer: ?*anyopaque, bytesToRead: usize, pBytesRead: ?*usize) callconv(.c) c.ma_result {
	_ = pVfs;
	const vfsHandle = getFile(pFile) catch return c.MA_INVALID_ARGS;
	if(pBuffer == null) return c.MA_INVALID_ARGS;

	const buffer = @as([*]u8, @ptrCast(@alignCast(pBuffer.?)))[0..bytesToRead];

	const bytesRead = vfsHandle.file.read(buffer) catch |err| {
		if(err == error.EndOfStream) {
			return c.MA_AT_END;
		} else {
			return c.MA_ERROR;
		}
	};

	if(pBytesRead) |p| p.* = bytesRead;

	if(bytesRead < bytesToRead) {
		return c.MA_AT_END;
	}

	return c.MA_SUCCESS;
}

fn vfsOnSeek(pVfs: ?*c.ma_vfs, pFile: c.ma_vfs_file, offset: c.ma_int64, origin: c.ma_seek_origin) callconv(.c) c.ma_result {
	_ = pVfs;
	const vfsHandle = getFile(pFile) catch return c.MA_INVALID_ARGS;

	switch(origin) {
		c.ma_seek_origin_start => vfsHandle.file.seekTo(@intCast(offset)) catch return c.MA_ERROR,
		c.ma_seek_origin_current => vfsHandle.file.seekBy(offset) catch return c.MA_ERROR,
		c.ma_seek_origin_end => vfsHandle.file.seekFromEnd(offset) catch return c.MA_ERROR,
		else => return c.MA_INVALID_ARGS,
	}
	return c.MA_SUCCESS;
}

fn vfsOnTell(pVfs: ?*c.ma_vfs, pFile: c.ma_vfs_file, pCursor: ?*c.ma_int64) callconv(.c) c.ma_result {
	_ = pVfs;
	if(pCursor == null) return c.MA_INVALID_ARGS;

	const vfsHandle = getFile(pFile) catch return c.MA_INVALID_ARGS;

	const pos = vfsHandle.file.getPos() catch return c.MA_ERROR;
	pCursor.?.* = @intCast(pos);
	return c.MA_SUCCESS;
}

fn vfsOnInfo(pVfs: ?*c.ma_vfs, pFile: c.ma_vfs_file, pInfo: ?*c.ma_file_info) callconv(.c) c.ma_result {
	_ = pVfs;
	if(pInfo == null) return c.MA_INVALID_ARGS;

	const vfsHandle = getFile(pFile) catch return c.MA_INVALID_ARGS;

	const size = vfsHandle.file.getEndPos() catch return c.MA_ERROR;
	pInfo.?.*.sizeInBytes = size;

	return c.MA_SUCCESS;
}

var vfs: c.ma_vfs_callbacks = .{
	.onOpen = vfsOnOpen,
	.onOpenW = null,
	.onClose = vfsOnClose,
	.onRead = vfsOnRead,
	.onWrite = null,
	.onSeek = vfsOnSeek,
	.onTell = vfsOnTell,
	.onInfo = vfsOnInfo,
};

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

var engine: c.ma_engine = undefined;
var resourceManager: c.ma_resource_manager = undefined;
var log: c.ma_log = undefined;

var mutex: std.Thread.Mutex = .{};

fn handleError(miniaudioError: c.ma_result) !void {
	if(miniaudioError != c.MA_SUCCESS) {
		std.log.err("miniaudio error: {s}", .{c.ma_result_description(miniaudioError)});
		return error.miniaudioError;
	}
}

pub fn init() !void {
	try handleError(c.ma_log_init(null, &log));
	const callback = c.ma_log_callback_init(onLog, null);
	try handleError(c.ma_log_register_callback(&log, callback));

	var resourceManagerConfig = c.ma_resource_manager_config_init();
	resourceManagerConfig.pLog = &log;
	resourceManagerConfig.pVFS = &vfs;
	try handleError(c.ma_resource_manager_init(&resourceManagerConfig, &resourceManager));

	var engineConfig = c.ma_engine_config_init();
	engineConfig.pLog = &log;
	engineConfig.pResourceManager = &resourceManager;
	try handleError(c.ma_engine_init(&engineConfig, &engine));
}

pub fn deinit() void {
	mutex.lock();
	defer mutex.unlock();

	if(currentMusicId.len > 0) {
		main.globalAllocator.free(currentMusicId);
	}
	currentMusicId = "";

	if(music) |sound| {
		c.ma_sound_uninit(sound);
		main.globalAllocator.destroy(sound);
		music = null;
	}

	c.ma_engine_uninit(&engine);
	c.ma_resource_manager_uninit(&resourceManager);
	c.ma_log_uninit(&log);
}

pub fn setMasterVolume(volume: f32) void {
	_ = c.ma_engine_set_volume(&engine, volume);
}

var music: ?*c.ma_sound = null;
var musicDataSource: ?*c.ma_resource_manager_data_source = null;
var currentMusicId: []const u8 = "";

pub fn setMusic(musicId: []const u8) void {
	mutex.lock();
	defer mutex.unlock();

	if(std.mem.eql(u8, musicId, currentMusicId)) return;
	if(musicId.len == 0) return;

	const colonIndex = std.mem.indexOfScalar(u8, musicId, ':') orelse {
		std.log.err("Invalid music id: {s}. Must be of the form 'addon:file_name'", .{musicId});
		return;
	};
	const addon = musicId[0..colonIndex];
	const fileName = musicId[colonIndex + 1 ..];

	const newDataSource = main.globalAllocator.create(c.ma_resource_manager_data_source);

	const path1 = std.fmt.allocPrintSentinel(main.stackAllocator.allocator, "assets/{s}/music/{s}.ogg", .{addon, fileName}, 0) catch unreachable;
	defer main.stackAllocator.free(path1);

	var result = c.ma_resource_manager_data_source_init(&resourceManager, path1, 0, null, newDataSource);
	if(result != c.MA_SUCCESS) {
		const path2 = std.fmt.allocPrintSentinel(main.stackAllocator.allocator, "{s}/serverAssets/{s}/music/{s}.ogg", .{main.files.cubyzDirStr(), addon, fileName}, 0) catch unreachable;
		defer main.stackAllocator.free(path2);

		result = c.ma_resource_manager_data_source_init(&resourceManager, path2, 0, null, newDataSource);
		if(result != c.MA_SUCCESS) {
			std.log.err("Failed to load music '{s}' via resource manager: {s}.", .{musicId, c.ma_result_description(result)});
			main.globalAllocator.destroy(newDataSource);
			return;
		}
	}

	const newMusic = main.globalAllocator.create(c.ma_sound);
	const flags = c.MA_SOUND_FLAG_STREAM | c.MA_SOUND_FLAG_NO_PITCH | c.MA_SOUND_FLAG_NO_SPATIALIZATION;
	result = c.ma_sound_init_from_data_source(&engine, newDataSource, flags, null, newMusic);
	if(result != c.MA_SUCCESS) {
		std.log.err("Failed to init sound from data source for '{s}': {s}.", .{musicId, c.ma_result_description(result)});
		_ = c.ma_resource_manager_data_source_uninit(newDataSource);
		main.globalAllocator.destroy(newMusic);
		main.globalAllocator.destroy(newDataSource);
		return;
	}

	c.ma_sound_set_looping(newMusic, c.MA_TRUE);

	if(c.ma_sound_start(newMusic) != c.MA_SUCCESS) {
		std.log.err("Failed to start new sound '{s}'", .{musicId});
		c.ma_sound_uninit(newMusic);
		_ = c.ma_resource_manager_data_source_uninit(newDataSource);
		main.globalAllocator.destroy(newMusic);
		main.globalAllocator.destroy(newDataSource);
		return;
	}

	if(music) |sound| {
		c.ma_sound_uninit(sound);
		main.globalAllocator.destroy(sound);
	}
	if(musicDataSource) |dataSource| {
		_ = c.ma_resource_manager_data_source_uninit(dataSource);
		main.globalAllocator.destroy(dataSource);
	}
	if(currentMusicId.len > 0) {
		main.globalAllocator.free(currentMusicId);
	}

	music = newMusic;
	musicDataSource = newDataSource;
	currentMusicId = main.globalAllocator.dupe(u8, musicId);
}
