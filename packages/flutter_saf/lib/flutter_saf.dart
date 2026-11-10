import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart' as f;
import 'flutter_saf_platform_interface.dart';
import 'package:flutter/services.dart';


final class _DirContent extends Struct {
  external Pointer<f.Utf8> folders;
  external Pointer<Int32> folderDescriptors;
  external Pointer<f.Utf8> files;
  external Pointer<Int32> fileDescriptors;
}

final class _FileContent extends Struct {
  external Pointer<Uint8> data;
  @Int32()
  external int size;
}

class _AndroidNativePathFuncProxy {
  static _AndroidNativePathFuncProxy instance = _AndroidNativePathFuncProxy._();

  //throws uninitialized exception on non-android platform when trying to call these
  late final void Function(int descriptor) deleteDescriptor;
  late final Pointer<_DirContent> Function(int descriptor) _listDir;
  late final int Function(Pointer<f.Utf8> path) _openDir;
  late final int Function(int descriptor) getParent;
  late final int Function(Pointer<f.Utf8> path, bool recursive) _createDir;
  late final int Function(int descriptor, Pointer<f.Utf8> path) _renameDir;
  late final int Function(int descriptor, bool recursive) deleteDir;
  late final int Function(int descriptor) getFileSize;
  late final Pointer<f.Utf8> Function(int descriptor) _statDoc;
  late final int Function(Pointer<f.Utf8> path, bool recursive) _createFile;
  late final int Function(int descriptor, Pointer<f.Utf8> path, bool copy)
      _renameFile;
  late final int Function(int descriptor) deleteFile;
  late final Pointer<_FileContent> Function(int d) _fileReadAllBytes;
  late final int Function(int d, Pointer<Uint8> p, int s, int a) _fileWriteAllBytes;

  late final int Function(int descriptor, int mode) _openFile;
  late final int Function(int d) closeFile;
  late final int Function(int d) flushFile;
  late final int Function(int d) fileSize;
  late final int Function(int d) ftell;
  late final int Function(int d) readByte;
  late final int Function(int d, Pointer<Uint8> b, int c) readBytes;
  late final int Function(int d, int b) writeByte;
  late final int Function(int d, Pointer<Uint8> b, int c) writeBytes;
  late final int Function(int d, int p) fseek;

  late final Pointer<Void> Function(int) malloc;
  late final Pointer<NativeFinalizerFunction> nativeFree;
  late final void Function(Pointer<Void>) free;

  _AndroidNativePathFuncProxy._() {
    if(Platform.isAndroid) {
      final DynamicLibrary nativeLib = DynamicLibrary.open('libflutter-saf.so');

      malloc = nativeLib.lookup<NativeFunction<Pointer<Void> Function(Int32)>>('_malloc').asFunction();
      nativeFree = nativeLib.lookup<NativeFunction<Void Function(Pointer<Void>)>>('_free');
      free = nativeFree.asFunction();

      _listDir = nativeLib
          .lookup<NativeFunction<Pointer<_DirContent> Function(Int32)>>(
              'listDir')
          .asFunction();
      _openDir = nativeLib
          .lookup<NativeFunction<Int32 Function(Pointer<f.Utf8>)>>('openDir')
          .asFunction();
      getParent = nativeLib.lookup<NativeFunction<Int32 Function(Int32)>>('getParent').asFunction();
      _createDir = nativeLib
          .lookup<NativeFunction<Int32 Function(Pointer<f.Utf8>, Bool)>>(
              'createDir')
          .asFunction();
      _createFile = nativeLib
          .lookup<NativeFunction<Int32 Function(Pointer<f.Utf8>, Bool)>>(
              'createFile')
          .asFunction();
      deleteDescriptor = nativeLib
          .lookup<NativeFunction<Void Function(Int32)>>('deleteDescriptor')
          .asFunction();
      deleteDir = nativeLib.lookup<NativeFunction<Int32 Function(Int32, Bool)>>('deleteDir').asFunction();
      _statDoc = nativeLib.lookupFunction<Pointer<f.Utf8> Function(Int32), Pointer<f.Utf8> Function(int)>('statDoc');
      getFileSize = nativeLib.lookup<NativeFunction<Int32 Function(Int32)>>('getFileSize').asFunction();
      _renameDir = nativeLib
          .lookup<NativeFunction<Int32 Function(Int32, Pointer<f.Utf8>)>>(
              'renameDir')
          .asFunction();
      _renameFile = nativeLib
          .lookup<NativeFunction<Int32 Function(Int32, Pointer<f.Utf8>, Bool)>>(
              'renameFile')
          .asFunction();
      deleteFile = nativeLib.lookup<NativeFunction<Int32 Function(Int32)>>('deleteFile').asFunction();
      _fileReadAllBytes = nativeLib.lookup<NativeFunction<Pointer<_FileContent> Function(Int32)>>('fileReadAllBytes').asFunction();
      _fileWriteAllBytes = nativeLib.lookup<NativeFunction<Int32 Function(Int32, Pointer<Uint8>, Int32, Int32)>>('fileWriteAllBytes').asFunction();

      _openFile = nativeLib.lookup<NativeFunction<Int32 Function(Int32, Int32)>>('_fopen').asFunction();
      closeFile = nativeLib.lookup<NativeFunction<Int32 Function(Int32)>>('_fclose').asFunction();
      flushFile = nativeLib.lookup<NativeFunction<Int32 Function(Int32)>>('_fflush').asFunction();
      fileSize = nativeLib.lookup<NativeFunction<Int32 Function(Int32)>>('_fsize').asFunction();
      ftell = nativeLib.lookup<NativeFunction<Int32 Function(Int32)>>('_ftell').asFunction();
      readByte = nativeLib.lookup<NativeFunction<Int32 Function(Int32)>>('_freadByte').asFunction();
      readBytes = nativeLib.lookup<NativeFunction<Int32 Function(Int32, Pointer<Uint8>, Int32)>>('_fread').asFunction();
      writeByte = nativeLib.lookup<NativeFunction<Int32 Function(Int32, Int32)>>('_fwriteByte').asFunction();
      writeBytes = nativeLib.lookup<NativeFunction<Int32 Function(Int32, Pointer<Uint8>, Int32)>>('_fwrite').asFunction();
      fseek = nativeLib.lookup<NativeFunction<Int32 Function(Int32, Int32)>>('_fseek').asFunction();
    }
  }

  int openDir(String path) {
    Pointer<f.Utf8> pathStr = path.toNativeUtf8();
    var result = _openDir(pathStr);
    f.malloc.free(pathStr);
    return result;
  }

  int createDir(String path, bool r) {
    Pointer<f.Utf8> pathStr = path.toNativeUtf8();
    var result = _createDir(pathStr, r);
    f.malloc.free(pathStr);
    return result;
  }

  int createFile(String path, bool r) {
    Pointer<f.Utf8> pathStr = path.toNativeUtf8();
    var result = _createFile(pathStr, r);
    f.malloc.free(pathStr);
    return result;
  }

  int renameDir(int descriptor, String newName) {
    Pointer<f.Utf8> pathStr = newName.toNativeUtf8();
    var result = _renameDir(descriptor, pathStr);
    f.malloc.free(pathStr);
    return result;
  }

  int renameFile(int descriptor, String newName, bool copy) {
    Pointer<f.Utf8> pathStr = newName.toNativeUtf8();
    var result = _renameFile(descriptor, pathStr, copy);
    f.malloc.free(pathStr);
    return result;
  }

  int openFile(int descriptor, FileMode mode) {
    var ret = _AndroidNativePathFuncProxy.instance
        ._openFile(descriptor, fileModeToInt(mode));
    return ret;
  }

  Uint8List fileReadAllBytes(int descriptor) {
    var result = _fileReadAllBytes(descriptor);
    if(result.ref.size != -1) {
      var size = result.ref.size;
      var data = result.ref.data;
      _AndroidNativeAllocator.instance.free(result);
      return data.asTypedList(size,
          finalizer: _AndroidNativeAllocator.instance.nativeFree);
    } else {
      _AndroidNativeAllocator.instance.free(result.ref.data);
      _AndroidNativeAllocator.instance.free(result);
      throw const FileSystemException("Failed to read SAF document");
    }
  }

  int fileModeToInt(FileMode m) {
    return switch(m) {
      FileMode.read => 0,
      FileMode.write => 1,
      FileMode.append => 2,
      FileMode.writeOnly => 3,
      FileMode.writeOnlyAppend => 4,
      FileMode() => throw UnimplementedError(),
    };
  }

  int fileWriteAllBytes(int descriptor, List<int> bytes, FileMode m) {
    var p = _AndroidNativeAllocator.instance.allocate<Uint8>(bytes.length);
    var arr = p.asTypedList(bytes.length);
    arr.setAll(0, bytes);
    var ret = _fileWriteAllBytes(descriptor, p, bytes.length, fileModeToInt(m));
    _AndroidNativeAllocator.instance.free(p);
    if (ret != bytes.length) throw const FileSystemException("Failed to write SAF document");
    return ret;
  }
}

class _AndroidNativeAllocator implements Allocator {
  _AndroidNativeAllocator._();

  static _AndroidNativeAllocator instance = _AndroidNativeAllocator._();

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    return _AndroidNativePathFuncProxy.instance.malloc(byteCount).cast<T>();
  }

  @override
  void free(Pointer<NativeType> pointer) {
    _AndroidNativePathFuncProxy.instance.free(pointer.cast<Void>());
  }

  final Pointer<NativeFinalizerFunction> nativeFree =
      _AndroidNativePathFuncProxy.instance.nativeFree;
}

void isolateWorker(SendPort sp) {
  final p = ReceivePort();
  sp.send(p.sendPort);

  p.listen((mes) async {
    if(mes is List) {
      final task = mes[0] as int;
      final name = mes[1] as Function;
      final args = mes[2] as List<dynamic>;
      final port = mes[3] as SendPort;

      dynamic result;
      try {
        result = await Function.apply(name, args);
      } catch(e) {
        port.send([task, null, e.toString()]);
        return;
      }

      port.send([task, result]);
    }
  });
}

class SAFTaskWorker {
  factory SAFTaskWorker() =>
      instance ?? (instance = SAFTaskWorker._());

  SAFTaskWorker._();

  static SAFTaskWorker? instance;

  late Isolate _isolate;
  late SendPort _sendPort;
  final _responsePort = ReceivePort();
  final _completerMap = <int, Completer>{};

  Future<void> init() async {
    final readyPort = ReceivePort();
    _isolate = await Isolate.spawn(isolateWorker, readyPort.sendPort);

    _sendPort = await readyPort.first as SendPort;

    _responsePort.listen((message) {
      if (message is List) {
        final taskId = message[0] as int;
        final result = message[1];
        final completer = _completerMap.remove(taskId);
        if (completer != null) {
          if (message.length > 2) {
            completer.completeError(FileSystemException(message[2] as String));
          } else {
            completer.complete(result);
          }
        }
      }
    });
  }

  Future<T> runTask<T>(Function func, List<dynamic> args) {
    final completer = Completer<T>();
    _completerMap[completer.hashCode] = completer;

    _sendPort.send([completer.hashCode, func, args, _responsePort.sendPort]);
    return completer.future;
  }

  void dispose() {
    _responsePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

// String _generateRandomString(int length) {
//   final rand = Random();
//   const chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz0123456789';
//   return Iterable.generate(
//     length, (_) => chars[rand.nextInt(chars.length)],
//   ).toList().join();
// }

class _Document {
  static const String mediaPrefix = "android://";
  String _myPath;//resolved path
  int _handle;
  int get _descriptor => _handle;
  set _descriptor(int value) {
    _finalizer.detach(this);
    if (_handle > 0) _AndroidNativePathFuncProxy.instance.deleteDescriptor(_handle);
    _handle = value;
    _finalizer.attach(this, value, detach: this);
  }
  static final _finalizer = Finalizer<int>((value) {
    if (value > 0) _AndroidNativePathFuncProxy.instance.deleteDescriptor(value);
  });
  _Document(this._myPath, this._handle);


  static Future<_Document?> _refreshDoc(String path) {
    if (!path.startsWith(mediaPrefix)) {
      return Future.value(null);
    }
    return SAFTaskWorker().runTask<int>(
        _AndroidNativePathFuncProxy.instance.openDir, [path]).then((result) {
      if (result < -1) {
        return null;
      }
      return _Document(path, result);
    });
  }

  static _Document? _refreshDocSync(String path) {
    if (!path.startsWith(mediaPrefix)) {
      return null;
    }
    var result = _AndroidNativePathFuncProxy.instance.openDir(path);
    if (result < -1) {
      return null;
    }
    return _Document(path, result);
  }
}

class AndroidDirectory extends _Document implements Directory {
  AndroidDirectory._(super._myPath, super._handle) {
    _Document._finalizer.attach(this, _descriptor, detach: this);
  }

  static Future<AndroidDirectory?> pickDirectory() async {
    return FlutterSafPlatform.instance.pick().then((result) {
      if(result != null) {
        return AndroidDirectory._(
            result[0],
            int.parse(result[1])
        );
      }
      return null;
    });
  }

  static AndroidDirectory? fromPathSync(String path) {
    var doc = _Document._refreshDocSync(path);
    if(doc == null) {
      return null;
    }
    return AndroidDirectory._(doc._myPath, doc._descriptor);
  }

  static Future<AndroidDirectory?> fromPath(String path) async {
    return _Document._refreshDoc(path).then((result) {
      if(result == null) {
        return null;
      }
      return AndroidDirectory._(result._myPath, result._descriptor);
    });
  }

  @override
  Directory get absolute => this;

  @override
  Future<Directory> create({bool recursive = false}) async {
    if(_descriptor == 0) {
      throw FileSystemException("Cannot create directory specified.", _myPath);
    }
    return SAFTaskWorker().runTask<int>(
        _AndroidNativePathFuncProxy.instance.createDir,
        [_myPath, recursive]).then((result) {
      if (result < 0) {
        throw FileSystemException("Cannot create directory specified.", _myPath);
      }
      _descriptor = result;
      return this;
    });
  }

  @override
  void createSync({bool recursive = false}) {
    if(_descriptor == 0) {
      return;
    }
    var result =
        _AndroidNativePathFuncProxy.instance.createDir(_myPath, recursive);
    if (result < 0) {
      throw FileSystemException("Cannot create directory specified.", _myPath);
    }
    _descriptor = result;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    return SAFTaskWorker().runTask(
        _AndroidNativePathFuncProxy.instance.deleteDir,
        [_descriptor, recursive]).then((result) {
      switch (result) {
        case 0:
          _descriptor = -1;
        case -1:
          throw FileSystemException("Directory path is invalid", _myPath);
        case -3:
          throw FileSystemException("Directory is not empty", _myPath);
        //unbelievable
        case -2:
          throw FileSystemException("Directory descriptor is invalid", _myPath);
      }
      return this;
    });
  }

  @override
  void deleteSync({bool recursive = false}) {
    var result =
        _AndroidNativePathFuncProxy.instance.deleteDir(_descriptor, recursive);
    switch(result) {
      case 0 : _descriptor = -1;
      case -1: throw FileSystemException("Directory path is invalid", _myPath);
      case -3: throw FileSystemException("Directory is not empty", _myPath);
      //unbelievable
      case -2: throw FileSystemException("Directory descriptor is invalid", _myPath);
    }
  }

  @override
  Future<bool> exists() async {
    final descriptor = await SAFTaskWorker().runTask<int>(_AndroidNativePathFuncProxy.instance.openDir, [_myPath]);
    _descriptor = descriptor;
    return descriptor >= 0;
  }

  @override
  bool existsSync() {
    _descriptor = _AndroidNativePathFuncProxy.instance.openDir(_myPath);
    return _descriptor >= 0;
  }

  @override
  bool get isAbsolute => true;

  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) async* {
    if(_descriptor < 0) {
      throw FileSystemException("Cannot list missing SAF directory", _myPath);
    }

    var dc = await SAFTaskWorker()
        .runTask(_AndroidNativePathFuncProxy.instance._listDir, [_descriptor]);
    final Pointer<_DirContent> dirContent = dc.cast<_DirContent>();
    if (dirContent == nullptr) throw FileSystemException("Failed to list SAF directory", _myPath);
    var f1 = dirContent.ref.folders.toDartString();
    _AndroidNativeAllocator.instance.free(dirContent.ref.folders);
    if (f1.isNotEmpty) {
      var dirs = f1.split('|').map(Uri.decodeComponent).toList();
      // Own the descriptor values before recursive calls or async yields.
      final f1h = dirContent.ref.folderDescriptors
          .asTypedList(dirs.length).toList(growable: false);
      _AndroidNativeAllocator.instance.free(dirContent.ref.folderDescriptors);
      for (var i = 0; i < dirs.length; i++) {
        var d = AndroidDirectory._("$_myPath/${dirs[i]}", f1h[i]);
        yield d;
        if (recursive) {
          yield* d.list(recursive: recursive, followLinks: followLinks);
        }
      }
    }

    var f2 = dirContent.ref.files.toDartString();
    _AndroidNativeAllocator.instance.free(dirContent.ref.files);
    if (f2.isNotEmpty) {
      var files = f2.split('|').map(Uri.decodeComponent).toList();
      // Own the descriptor values before recursive calls or async yields.
      final f2h = dirContent.ref.fileDescriptors
          .asTypedList(files.length).toList(growable: false);
      _AndroidNativeAllocator.instance.free(dirContent.ref.fileDescriptors);
      for (var i = 0; i < files.length; i++) {
        yield AndroidFile._("$_myPath/${files[i]}", f2h[i]);
      }
    }
    _AndroidNativeAllocator.instance.free(dirContent);
  }

  @override
  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) {
    var result = <FileSystemEntity>[];
    if(_descriptor < 0) {
      throw FileSystemException("Cannot list missing SAF directory", _myPath);
    }

    var contents = _AndroidNativePathFuncProxy.instance._listDir(_descriptor);
    if (contents == nullptr) throw FileSystemException("Failed to list SAF directory", _myPath);
    var f1 = contents.ref.folders.toDartString();
    _AndroidNativeAllocator.instance.free(contents.ref.folders);
    if (f1.isNotEmpty) {
      var dirs = f1.split('|').map(Uri.decodeComponent).toList();
      // Own the descriptor values before recursive calls or async yields.
      final f1h = contents.ref.folderDescriptors
          .asTypedList(dirs.length).toList(growable: false);
      _AndroidNativeAllocator.instance.free(contents.ref.folderDescriptors);
      for (var i = 0; i < dirs.length; i++) {
        var d = AndroidDirectory._("$_myPath/${dirs[i]}", f1h[i]);
        result.add(d);
        if (recursive) {
          result.addAll(
              d.listSync(recursive: recursive, followLinks: followLinks));
        }
      }
    }

    var f2 = contents.ref.files.toDartString();
    _AndroidNativeAllocator.instance.free(contents.ref.files);
    if (f2.isNotEmpty) {
      var files = f2.split('|').map(Uri.decodeComponent).toList();
      // Own the descriptor values before recursive calls or async yields.
      final f2h = contents.ref.fileDescriptors
          .asTypedList(files.length).toList(growable: false);
      _AndroidNativeAllocator.instance.free(contents.ref.fileDescriptors);
      for (var i = 0; i < files.length; i++) {
        result.add(AndroidFile._("$_myPath/${files[i]}", f2h[i]));
      }
    }
    _AndroidNativeAllocator.instance.free(contents);
    return result;
  }

  @override
  Directory get parent {
    final separator = _myPath.lastIndexOf('/');
    final path = separator < _Document.mediaPrefix.length
        ? _Document.mediaPrefix : _myPath.substring(0, separator);
    return AndroidDirectory.fromPathSync(path)!;
  }

  @override
  String get path => _myPath;

  @override
  Future<Directory> rename(String newPath) async {
    if(_descriptor == -1) {
      throw FileSystemException("Cannot rename because the directory doesn't exist.", _myPath);
    }
    if(_descriptor == 0) {
      throw FileSystemException("Cannot rename because the directory is a root directory.", _myPath);
    }
    return SAFTaskWorker().runTask<int>(
        _AndroidNativePathFuncProxy.instance.renameDir,
        [_descriptor, newPath]).then((result) {
      if (result < 0) {
        if (result == -3) {
          return Directory(newPath);
        }
        throw FileSystemException("Rename failed", _myPath);
      }
      _myPath = newPath;
      _descriptor = result;
      return this;
    });
  }

  @override
  Directory renameSync(String newPath) {
    if(_descriptor == -1) {
      throw FileSystemException("Cannot rename because the directory doesn't exist.", _myPath);
    }
    if(_descriptor == 0) {
      throw FileSystemException("Cannot rename because the directory is a root directory.", _myPath);
    }
    var result =
        _AndroidNativePathFuncProxy.instance.renameDir(_descriptor, newPath);
    if (result < 0) {
      if (result == -3) {
        return Directory(newPath);
      }
      throw FileSystemException("Rename failed", _myPath);
    }
    _myPath = newPath;
    _descriptor = result;
    return this;
  }

  // TODO: region not implemented
  @override
  Future<Directory> createTemp([String? prefix]) {
    throw UnimplementedError();
  }

  @override
  Directory createTempSync([String? prefix]) {
    throw UnimplementedError();
  }

  @override
  Future<String> resolveSymbolicLinks() {
    throw UnimplementedError();
  }

  @override
  String resolveSymbolicLinksSync() {
    throw UnimplementedError();
  }

  @override
  Future<FileStat> stat() async => SAFTaskWorker().runTask(_readStat, [_descriptor]);

  @override
  FileStat statSync() => _readStat(_descriptor);

  @override
  Uri get uri => throw UnimplementedError();

  @override
  Stream<FileSystemEvent> watch({int events = FileSystemEvent.all, bool recursive = false}) {
    throw UnimplementedError();
  }
}

class AndroidFile extends _Document implements File {
  AndroidFile._(super._myPath, super._handle) {
    _Document._finalizer.attach(this, _descriptor, detach: this);
  }

  static AndroidFile? fromPathSync(String path) {
    var doc = _Document._refreshDocSync(path);
    if(doc == null) {
      return null;
    }
    return AndroidFile._(doc._myPath, doc._descriptor);
  }

  static Future<AndroidFile?> fromPath(String path) async {
    return _Document._refreshDoc(path).then((result) {
      if(result == null) {
        return null;
      }
      return AndroidFile._(result._myPath, result._descriptor);
    });
  }

  @override
  File get absolute => this;

  @override
  Future<File> copy(String newPath) {
    if(_descriptor == -1) {
      throw FileSystemException("Cannot copy because the file doesn't exist.", _myPath);
    }
    if(_descriptor == 0) {
      throw FileSystemException("Cannot copy because the file is a root directory.", _myPath);
    }
    return SAFTaskWorker().runTask<int>(
        _AndroidNativePathFuncProxy.instance.renameFile,
        [_descriptor, newPath, true]).then((result) {
      if (result < 0) {
        if (result == -3) {
          return File(newPath);
        }
        throw FileSystemException("Copy failed", _myPath);
      }
      return AndroidFile._(newPath, result);
    });
  }

  @override
  File copySync(String newPath) {
    if(_descriptor == -1) {
      throw FileSystemException("Cannot copy because the file doesn't exist.", _myPath);
    }
    if(_descriptor == 0) {
      throw FileSystemException("Cannot copy because the file is a root directory.", _myPath);
    }
    var result = _AndroidNativePathFuncProxy.instance
        .renameFile(_descriptor, newPath, true);
    if (result < 0) {
      if (result == -3) {
        return File(newPath);
      }
      throw FileSystemException("Copy failed", _myPath);
    }
    return AndroidFile._(newPath, result);
  }

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) {
    if(_descriptor == 0) {
      throw FileSystemException("Cannot create directory specified.", _myPath);
    }
    return SAFTaskWorker().runTask<int>(
        _AndroidNativePathFuncProxy.instance.createFile,
        [_myPath, recursive]).then((result) {
      if (result < 0) {
        if (result == -3) {
          return File(_myPath);
        }
        throw FileSystemException("Cannot create file specified.", _myPath);
      }
      _descriptor = result;
      return this;
    });
  }

  @override
  void createSync({bool recursive = false, bool exclusive = false}) {
    if(_descriptor == 0) {
      return;
    }
    var result =
        _AndroidNativePathFuncProxy.instance.createFile(_myPath, recursive);
    if (result < 0) {
      throw FileSystemException("Cannot create file specified.", _myPath);
    }
    _descriptor = result;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    return SAFTaskWorker().runTask<int>(
        _AndroidNativePathFuncProxy.instance.deleteFile,
        [_descriptor]).then((result) {
      switch (result) {
        case 0:
          _descriptor = -1;
        case -1:
          throw FileSystemException("Directory path is invalid", _myPath);
        case -3:
          throw FileSystemException("Directory is not empty", _myPath);
        //unbelievable
        case -2:
          throw FileSystemException("Directory descriptor is invalid", _myPath);
      }
      return this;
    });
  }

  @override
  void deleteSync({bool recursive = false}) {
    var result = _AndroidNativePathFuncProxy.instance.deleteFile(_descriptor);
    switch(result) {
      case 0 : _descriptor = -1;
      case -1: throw FileSystemException("Directory path is invalid", _myPath);
      case -3: throw FileSystemException("Directory is not empty", _myPath);
      //unbelievable
      case -2: throw FileSystemException("Directory descriptor is invalid", _myPath);
    }
  }

  @override
  Future<bool> exists() async {
    final descriptor = await SAFTaskWorker().runTask<int>(_AndroidNativePathFuncProxy.instance.openDir, [_myPath]);
    _descriptor = descriptor;
    return descriptor >= 0;
  }

  @override
  bool existsSync() {
    _descriptor = _AndroidNativePathFuncProxy.instance.openDir(_myPath);
    return _descriptor >= 0;
  }

  @override
  bool get isAbsolute => true;

  @override
  Future<int> length() async => (await stat()).size;

  @override
  int lengthSync() => statSync().size;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) {
    return AndroidRandomAccessFile.open(_descriptor, _myPath, mode).then((f) {
      if(f == null) {
        throw FileSystemException("Cannot open file.", _myPath);
      }
      return f;
    });
  }

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    var f = AndroidRandomAccessFile.openSync(_descriptor, _myPath, mode);
    if(f == null) {
      throw FileSystemException("Cannot open file.", _myPath);
    }
    return f;
  }

  @override
  Directory get parent {
    final separator = _myPath.lastIndexOf('/');
    final path = separator < _Document.mediaPrefix.length
        ? _Document.mediaPrefix : _myPath.substring(0, separator);
    return AndroidDirectory.fromPathSync(path)!;
  }

  @override
  String get path => super._myPath;

  @override
  Future<Uint8List> readAsBytes() {
    return SAFTaskWorker().runTask<Uint8List>(
        _AndroidNativePathFuncProxy.instance.fileReadAllBytes, [_descriptor]);
  }

  @override
  Uint8List readAsBytesSync() {
    return _AndroidNativePathFuncProxy.instance.fileReadAllBytes(_descriptor);
  }

  @override
  Future<File> rename(String newPath) {
    if(_descriptor == -1) {
      throw FileSystemException("Cannot rename because the file doesn't exist.", _myPath);
    }
    if(_descriptor == 0) {
      throw FileSystemException("Cannot rename because the file is a root directory.", _myPath);
    }
    return SAFTaskWorker().runTask<int>(
        _AndroidNativePathFuncProxy.instance.renameFile,
        [_descriptor, newPath, false]).then((result) {
      if (result < 0) {
        if (result == -3) {
          return File(_myPath);
        }
        throw FileSystemException("Rename failed", _myPath);
      }
      _myPath = newPath;
      _descriptor = result;
      return this;
    });
  }

  @override
  File renameSync(String newPath) {
    if(_descriptor == -1) {
      throw FileSystemException("Cannot rename because the file doesn't exist.", _myPath);
    }
    if(_descriptor == 0) {
      throw FileSystemException("Cannot rename because the file is a root directory.", _myPath);
    }
    var result = _AndroidNativePathFuncProxy.instance
        .renameFile(_descriptor, newPath, false);
    if (result < 0) {
      if (result == -3) {
        return File(_myPath);
      }
      throw FileSystemException("Rename failed", _myPath);
    }
    _myPath = newPath;
    _descriptor = result;
    return this;
  }

  @override
  Future<File> writeAsBytes(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) async {
    if(_descriptor == -1) {
      return create(recursive: true).then((_) {
        return SAFTaskWorker().runTask(
            _AndroidNativePathFuncProxy.instance.fileWriteAllBytes,
            [_descriptor, bytes, mode]).then((_) {
          return this;
        });
      });
    } else {
      return SAFTaskWorker().runTask(
          _AndroidNativePathFuncProxy.instance.fileWriteAllBytes,
          [_descriptor, bytes, mode]).then((_) {
        return this;
      });
    }
  }

  @override
  void writeAsBytesSync(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) {
    if(_descriptor == -1) {
      createSync(recursive: true);
    }
    //Flush is always true
    _AndroidNativePathFuncProxy.instance
        .fileWriteAllBytes(_descriptor, bytes, mode);
  }

  // TODO: region not implement
  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    throw UnimplementedError();
  }

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) {
    throw UnimplementedError();
  }

  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) async => const LineSplitter().convert(await readAsString(encoding: encoding));

  @override
  List<String> readAsLinesSync({Encoding encoding = utf8}) => const LineSplitter().convert(readAsStringSync(encoding: encoding));

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async => encoding.decode(await readAsBytes());

  @override
  String readAsStringSync({Encoding encoding = utf8}) => encoding.decode(readAsBytesSync());

  @override
  Future<File> writeAsString(String contents, {FileMode mode = FileMode.write, Encoding encoding = utf8, bool flush = false}) => writeAsBytes(encoding.encode(contents), mode: mode, flush: flush);

  @override
  void writeAsStringSync(String contents, {FileMode mode = FileMode.write, Encoding encoding = utf8, bool flush = false}) => writeAsBytesSync(encoding.encode(contents), mode: mode, flush: flush);

  @override
  Uri get uri => throw UnimplementedError();

  @override
  Stream<FileSystemEvent> watch({int events = FileSystemEvent.all, bool recursive = false}) {
    throw UnimplementedError();
  }

  @override
  Future<DateTime> lastAccessed() {
    throw UnimplementedError();
  }

  @override
  DateTime lastAccessedSync() {
    throw UnimplementedError();
  }

  @override
  Future<DateTime> lastModified() async => (await stat()).modified;

  @override
  DateTime lastModifiedSync() => statSync().modified;

  @override
  Future<String> resolveSymbolicLinks() {
    throw UnimplementedError();
  }

  @override
  String resolveSymbolicLinksSync() {
    throw UnimplementedError();
  }

  @override
  Future setLastAccessed(DateTime time) {
    throw UnimplementedError();
  }

  @override
  void setLastAccessedSync(DateTime time) {
    throw UnimplementedError();
  }

  @override
  Future setLastModified(DateTime time) {
    throw UnimplementedError();
  }

  @override
  void setLastModifiedSync(DateTime time) {
    throw UnimplementedError();
  }

  @override
  Future<FileStat> stat() async => SAFTaskWorker().runTask(_readStat, [_descriptor]);

  @override
  FileStat statSync() => _readStat(_descriptor);
}

class AndroidRandomAccessFile implements RandomAccessFile{
  final String _myPath;
  int _fd;//file descriptor
  bool _isOperationPending = false;

  AndroidRandomAccessFile._(this._fd, this._myPath);

  static RandomAccessFile? openSync(
      int descriptor,
      String path,
      FileMode mode)
  {
    var fd = _AndroidNativePathFuncProxy.instance.openFile(descriptor, mode);
    if(fd <= 0) {
      return null;
    }
    return AndroidRandomAccessFile._(fd, path);
  }

  static Future<RandomAccessFile?> open(
      int descriptor,
      String path,
      FileMode mode)
  async {
    return SAFTaskWorker().runTask<int>(
        _AndroidNativePathFuncProxy.instance.openFile,
        [descriptor, mode]).then((fd) {
      if(fd <= 0) {
        return null;
      }
      return AndroidRandomAccessFile._(fd, path);
    });
  }

  int _singleOp(int Function(int d) func) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.", _myPath);
    }
    _isOperationPending = true;
    var v = func(_fd);
    _isOperationPending = false;
    if(v < 0) {
      throw FileSystemException("Failed to close file.", _myPath);
    }
    return v;
  }

  Future<int> _singleOpAsync(int Function(int d) func) async {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.", _myPath);
    }
    _isOperationPending = true;
    return SAFTaskWorker().runTask<int>(func, [_fd]).then((v) {
      _isOperationPending = false;
      if(v < 0) {
        throw FileSystemException("Failed to perform the operation.", _myPath);
      }
      return v;
    });
  }

  @override
  Future<void> close() {
    return _singleOpAsync(_AndroidNativePathFuncProxy.instance.closeFile)
        .then((v) {
      _fd = -1;
      return;
    });
  }

  @override
  void closeSync() {
    _singleOp(_AndroidNativePathFuncProxy.instance.closeFile);
    _fd = -1;
  }

  @override
  Future<RandomAccessFile> flush() {
    return _singleOpAsync(_AndroidNativePathFuncProxy.instance.flushFile)
        .then((v) {
      return this;
    });
  }

  @override
  void flushSync() {
    _singleOp(_AndroidNativePathFuncProxy.instance.flushFile);
  }

  @override
  Future<int> length() {
    return _singleOpAsync(_AndroidNativePathFuncProxy.instance.fileSize)
        .then((s) {
      return s;
    });
  }

  @override
  int lengthSync() {
    return _singleOp(_AndroidNativePathFuncProxy.instance.fileSize);
  }

  @override
  String get path => _myPath;

  @override
  Future<int> position() {
    return _singleOpAsync(_AndroidNativePathFuncProxy.instance.ftell).then((p) {
      return p;
    });
  }

  @override
  int positionSync() {
    return _singleOp(_AndroidNativePathFuncProxy.instance.ftell);
  }

  @override
  Future<Uint8List> read(int count) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.", _myPath);
    }
    _isOperationPending = true;

    if(count == 0) {
      return Future.value(<Uint8>[] as FutureOr<Uint8List>?);
    }

    final p = _AndroidNativeAllocator.instance.allocate<Uint8>(count);
    return SAFTaskWorker().runTask<int>(
        _AndroidNativePathFuncProxy.instance.readBytes,
        [_fd, p, count]).then((v) {
      _isOperationPending = false;
      if(v < 0) {
        _AndroidNativeAllocator.instance.free(p);
        throw FileSystemException("$_fd: Operation failed.", _myPath);
      }
      return p.asTypedList(v,
          finalizer: _AndroidNativeAllocator.instance.nativeFree);
    });
  }

  @override
  Future<int> readByte() {
    return _singleOpAsync(_AndroidNativePathFuncProxy.instance.readByte)
        .then((p) {
      return p;
    });
  }

  @override
  int readByteSync() {
    return _singleOp(_AndroidNativePathFuncProxy.instance.readByte);
  }

  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.", _myPath);
    }
    _isOperationPending = true;
    final count = end == null ? buffer.length - start : end - start;
    final p = _AndroidNativeAllocator.instance.allocate<Uint8>(count);
    return SAFTaskWorker().runTask<int>(
        _AndroidNativePathFuncProxy.instance.readBytes,
        [_fd, p, count]).then((ret) {
      if(ret < 0) {
        _AndroidNativeAllocator.instance.free(p);
        _isOperationPending = false;
        throw FileSystemException("$_fd: Operation failed.", _myPath);
      }

      final tp = p.asTypedList(ret);
      buffer.setAll(start, tp);

      _AndroidNativeAllocator.instance.free(p);
      _isOperationPending = false;
      return ret;
    });
  }

  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.", _myPath);
    }
    _isOperationPending = true;
    final count = end == null ? buffer.length - start : end - start;
    final p = _AndroidNativeAllocator.instance.allocate<Uint8>(count);
    final ret = _AndroidNativePathFuncProxy.instance.readBytes(_fd, p, count);
    _isOperationPending = false;
    if(ret < 0) {
      _AndroidNativeAllocator.instance.free(p);
      throw FileSystemException("$_fd: Operation failed.", _myPath);
    }

    final tp = p.asTypedList(ret);
    buffer.setAll(start, tp);

    _AndroidNativeAllocator.instance.free(p);
    _isOperationPending = false;
    return ret;
  }

  @override
  Uint8List readSync(int count) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.", _myPath);
    }
    _isOperationPending = true;
    final p = _AndroidNativeAllocator.instance.allocate<Uint8>(count);
    final ret = _AndroidNativePathFuncProxy.instance.readBytes(_fd, p, count);
    _isOperationPending = false;
    if(ret < 0) {
      _AndroidNativeAllocator.instance.free(p);
      throw FileSystemException("$_fd: Operation failed.", _myPath);
    }

    return p.asTypedList(ret,
        finalizer: _AndroidNativeAllocator.instance.nativeFree);
  }

  @override
  Future<RandomAccessFile> setPosition(int position) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.", _myPath);
    }
    _isOperationPending = true;
    return SAFTaskWorker().runTask<int>(
        _AndroidNativePathFuncProxy.instance.fseek, [_fd, position]).then((v) {
      _isOperationPending = false;
      if(v < 0) {
        throw FileSystemException("Failed to set position.", _myPath);
      }
      return this;
    });
  }

  @override
  void setPositionSync(int position) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.", _myPath);
    }
    _isOperationPending = true;
    var v = _AndroidNativePathFuncProxy.instance.fseek(_fd, position);
    _isOperationPending = false;
    if(v < 0) {
      throw FileSystemException("Failed to set position.", _myPath);
    }
  }

  @override
  Future<RandomAccessFile> writeByte(int value) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.");
    }
    _isOperationPending = true;
    return SAFTaskWorker().runTask(
        _AndroidNativePathFuncProxy.instance.writeByte, [_fd, value]).then((v) {
      _isOperationPending = false;
      if(v != 1) {
        throw FileSystemException("Failed to write byte.", _myPath);
      }
      return this;
    });
  }

  @override
  int writeByteSync(int value) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.");
    }
    _isOperationPending = true;
    var v = _AndroidNativePathFuncProxy.instance.writeByte(_fd, value);
    _isOperationPending = false;
    if(v != 1) {
      throw FileSystemException("Failed to write byte.", _myPath);
    }
    return v;
  }

  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer, [int start = 0, int? end]) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.");
    }
    _isOperationPending = true;
    var count = end == null ? buffer.length - start : end - start;
    var p = _AndroidNativeAllocator.instance.allocate<Uint8>(count);
    var a = p.asTypedList(count);
    a.setAll(0, buffer.getRange(start, start + count));
    return SAFTaskWorker().runTask(
        _AndroidNativePathFuncProxy.instance.writeBytes,
        [_fd, p, count]).then((v) {
      _isOperationPending = false;
      _AndroidNativeAllocator.instance.free(p);
      if(v != count) {
        throw FileSystemException("$_fd: Failed to write bytes.");
      }
      return this;
    });
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.");
    }
    _isOperationPending = true;
    var count = end == null ? buffer.length - start : end - start;
    var p = _AndroidNativeAllocator.instance.allocate<Uint8>(count);
    var a = p.asTypedList(count);
    a.setAll(0, buffer.getRange(start, start + count));
    var v = _AndroidNativePathFuncProxy.instance.writeBytes(_fd, p, count);
    _isOperationPending = false;
    _AndroidNativeAllocator.instance.free(p);
    if(v != count) {
      throw FileSystemException("$_fd: Failed to write bytes.");
    }
  }

  // TODO: region not implement
  @override
  Future<RandomAccessFile> writeString(String string, {Encoding encoding = utf8}) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.");
    }
    throw UnimplementedError();
  }

  @override
  void writeStringSync(String string, {Encoding encoding = utf8}) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.");
    }
  }

  @override
  Future<RandomAccessFile> truncate(int length) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.");
    }
    throw UnimplementedError();
  }

  @override
  void truncateSync(int length) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.");
    }
  }

  @override
  Future<RandomAccessFile> lock([FileLock mode = FileLock.exclusive, int start = 0, int end = -1]) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.");
    }
    throw UnimplementedError();
  }

  @override
  void lockSync([FileLock mode = FileLock.exclusive, int start = 0, int end = -1]) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.");
    }
  }

  @override
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.");
    }
    throw UnimplementedError();
  }

  @override
  void unlockSync([int start = 0, int end = -1]) {
    if(_isOperationPending) {
      throw FileSystemException("$_fd: Operation is pending.");
    }
  }
}

FileStat _readStat(int descriptor) {
  final proxy = _AndroidNativePathFuncProxy.instance;
  final pointer = proxy._statDoc(descriptor);
  if (pointer == nullptr) throw const FileSystemException('Cannot stat SAF document');
  try {
    return _SafFileStat(jsonDecode(pointer.toDartString()) as Map<String, dynamic>);
  } finally {
    proxy.free(pointer.cast());
  }
}

class _SafFileStat implements FileStat {
  _SafFileStat(Map<String, dynamic> data)
      : modified = DateTime.fromMillisecondsSinceEpoch(data['modified'] as int),
        size = data['size'] as int,
        type = data['directory'] == true ? FileSystemEntityType.directory : FileSystemEntityType.file;
  @override final DateTime modified;
  @override final int size;
  @override final FileSystemEntityType type;
  @override DateTime get accessed => modified;
  @override DateTime get changed => modified;
  @override int get mode => 0;
  @override String modeString() => '---------';
}
