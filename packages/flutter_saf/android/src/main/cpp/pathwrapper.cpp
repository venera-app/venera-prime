#define FFIEXPORT extern "C" __attribute__((visibility("default"))) __attribute__((used))
#include <jni.h>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <android/log.h>
#include <sys/stat.h>
#include <cerrno>
#include <climits>
#include <vector>
#include "file_io.h"

static struct {
    JavaVM * _vm;

    jclass _cls;
    jobject _clsInst;

    jmethodID openDir;
    jmethodID getParent;
    jmethodID listDir;
    jmethodID createDir;
    jmethodID renameDir;
    jmethodID deleteDescriptor;
    jmethodID deleteDir;
    jmethodID openFile;
    jmethodID getFileSize;
    jmethodID statDoc;
    jmethodID createFile;
    jmethodID renameFile;
    jmethodID deleteFile;

    jclass intClass;
    jmethodID int_intValue;
    jmethodID int_valueOf;

    jclass arrayListClass;
    jmethodID arraylist_get;
    jmethodID arraylist_size;

    jclass pairClass;
    jfieldID pair_first;
    jfieldID pair_second;
}s_instance{};

static const char* fileModes[] = {"r", "rwt", "wa", "wt", "wa"};

// Dart's worker pool retires idle threads. Only detach threads we attached;
// leaving them attached can make ART abort when a worker exits.
class ScopedJniEnv {
    JNIEnv* env = nullptr;
    bool attached = false;
public:
    ScopedJniEnv() {
        if (s_instance._vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6)
                == JNI_EDETACHED) {
            s_instance._vm->AttachCurrentThread(&env, nullptr);
            attached = true;
        }
        env->PushLocalFrame(32);
    }
    ~ScopedJniEnv() {
        env->PopLocalFrame(nullptr);
        if (attached) s_instance._vm->DetachCurrentThread();
    }
    JNIEnv* get() const { return env; }
};

FFIEXPORT
void* _malloc(int32_t size) {
    return malloc(size);
}

FFIEXPORT
void _free(void* ptr) {
    free(ptr);
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    s_instance._vm = vm;
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL JNI_OnUnload(JavaVM* vm, void* reserved)
{
    __android_log_print(ANDROID_LOG_DEBUG, "PathWrapper", "JNI_OnUnLoad");
}

//Flutter <-> cpp <-> kotlin
extern "C" JNIEXPORT void JNICALL
Java_org_pkuism_flutter_1saf_SAFPathWrapper_setupNativeProxy(JNIEnv* env, jobject instance) {
    s_instance._clsInst = env->NewGlobalRef(instance);

    jclass cls = env->GetObjectClass(instance);
    s_instance._cls = (jclass)env->NewGlobalRef(cls);
    s_instance.openDir = env->GetMethodID(cls, "onOpenPath", "(Ljava/lang/String;)I");
    s_instance.getParent = env->GetMethodID(cls, "getParent", "(I)I");
    s_instance.listDir = env->GetMethodID(cls, "listDirectory", "(I)Landroid/util/Pair;");
    s_instance.createDir = env->GetMethodID(cls, "createDirectory", "(Ljava/lang/String;Z)I");
    s_instance.deleteDescriptor = env->GetMethodID(cls, "deleteDocumentUri", "(I)V");
    s_instance.deleteDir = env->GetMethodID(cls, "deleteDir", "(IZ)I");
    s_instance.renameDir = env->GetMethodID(cls, "renameDirectory", "(ILjava/lang/String;)I");
    s_instance.openFile = env->GetMethodID(cls, "fopen", "(ILjava/lang/String;)I");
    s_instance.statDoc = env->GetMethodID(cls, "statDoc", "(I)Ljava/lang/String;");
    s_instance.getFileSize = env->GetMethodID(cls, "getFileSize", "(I)I");
    s_instance.createFile = env->GetMethodID(cls, "createDirectory", "(Ljava/lang/String;ZZ)I");
    s_instance.renameFile = env->GetMethodID(cls, "renameFile", "(ILjava/lang/String;Z)I");
    s_instance.deleteFile = env->GetMethodID(cls, "deleteFile", "(I)I");

    jclass intClass = env->FindClass("java/lang/Integer");
    s_instance.intClass = (jclass)env->NewGlobalRef(intClass);
    s_instance.int_intValue = env->GetMethodID(intClass, "intValue", "()I");
    s_instance.int_valueOf = env->GetStaticMethodID(intClass, "valueOf", "(I)Ljava/lang/Integer;");

    jclass arrayListClass = env->FindClass("java/util/ArrayList");
    s_instance.arrayListClass = (jclass)env->NewGlobalRef(arrayListClass);
    s_instance.arraylist_get = env->GetMethodID(arrayListClass, "get", "(I)Ljava/lang/Object;");
    s_instance.arraylist_size = env->GetMethodID(arrayListClass, "size", "()I");

    jclass pairClass = env->FindClass("android/util/Pair");
    s_instance.pairClass = (jclass)env->NewGlobalRef(pairClass);
    s_instance.pair_first = env->GetFieldID(pairClass, "first", "Ljava/lang/Object;");
    s_instance.pair_second = env->GetFieldID(pairClass, "second", "Ljava/lang/Object;");
}

extern "C" JNIEXPORT void JNICALL
Java_org_pkuism_flutter_1saf_SAFPathWrapper_destroyNativeProxy(JNIEnv* env, jobject instance) {
    env->DeleteGlobalRef(s_instance._clsInst);
    env->DeleteGlobalRef(s_instance._cls);
    env->DeleteGlobalRef(s_instance.intClass);
    env->DeleteGlobalRef(s_instance.arrayListClass);
    env->DeleteGlobalRef(s_instance.pairClass);
}

FFIEXPORT
void deleteDescriptor(int32_t descriptor) {
    if (descriptor <= 0) return;
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();

    env->CallVoidMethod(s_instance._clsInst, s_instance.deleteDescriptor, (jint)
    descriptor);
}

struct DirContent {
    int8_t *folders;
    int32_t *folder_descriptors;
    int8_t *files;
    int32_t *file_descriptors;
};
FFIEXPORT
DirContent* listDir(uint32_t descriptor) {
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();

    DirContent* dirInfo = nullptr;
    jobject pairRet = env->CallObjectMethod(s_instance._clsInst, s_instance.listDir, (jint)descriptor);
    if (!pairRet) return nullptr;
    jobject folders = env->GetObjectField(pairRet, s_instance.pair_first);

    auto foldersStr = (jstring) env->GetObjectField(folders, s_instance.pair_first);
    auto foldersHd = (jintArray) env->GetObjectField(folders, s_instance.pair_second);
    auto fdaSize = env->GetArrayLength(foldersHd);
    auto fda = env->GetIntArrayElements(foldersHd, nullptr);

    jobject files = (jstring) env->GetObjectField(pairRet, s_instance.pair_second);
    auto filesStr = (jstring) env->GetObjectField(files, s_instance.pair_first);
    auto filesHd = (jintArray) env->GetObjectField(files, s_instance.pair_second);
    auto fsaSize = env->GetArrayLength(filesHd);
    auto fsa = env->GetIntArrayElements(filesHd, nullptr);

    dirInfo = (DirContent*)malloc(sizeof(DirContent));
    if (fdaSize > 0) {
        dirInfo->folder_descriptors = (int32_t *) malloc(fdaSize * sizeof(int32_t));
        memcpy(dirInfo->folder_descriptors, fda, fdaSize * sizeof(int32_t));
    }
    if (fsaSize > 0) {
        dirInfo->file_descriptors = (int32_t *) malloc(fsaSize * sizeof(int32_t));
        memcpy(dirInfo->file_descriptors, fsa, fsaSize * sizeof(int32_t));
    }

    auto s1 = env->GetStringUTFChars(foldersStr, nullptr);
    auto s2 = env->GetStringUTFChars(filesStr, nullptr);
    dirInfo->folders = (int8_t *) strdup(s1);
    dirInfo->files = (int8_t *) strdup(s2);

    env->ReleaseIntArrayElements(foldersHd, fda, 0);
    env->ReleaseIntArrayElements(filesHd, fsa, 0);
    env->ReleaseStringUTFChars(foldersStr, s1);
    env->ReleaseStringUTFChars(filesStr, s2);

    return dirInfo;
}


FFIEXPORT
int32_t openDir(int8_t *path) {
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();

    jstring open_path = env->NewStringUTF((char*)path);
    return env->CallIntMethod(s_instance._clsInst, s_instance.openDir, open_path);
}

FFIEXPORT
int32_t getParent(int32_t descriptor) {
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();

    return env->CallIntMethod(s_instance._clsInst, s_instance.getParent, descriptor);
}

FFIEXPORT
int32_t createDir(int8_t *path, bool recursive) {
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();

    jstring create_path = env->NewStringUTF((char*)path);

    return env->CallIntMethod(s_instance._clsInst, s_instance.createDir, create_path, recursive);
}

FFIEXPORT
int32_t renameDir(int32_t descriptor, int8_t *newPath) {
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();

    jstring n = env->NewStringUTF((char*)newPath);

    return env->CallIntMethod(s_instance._clsInst, s_instance.renameDir, descriptor, n);
}

FFIEXPORT
int32_t deleteDir(int32_t descriptor, bool recursive) {
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();

    int32_t result = env->CallIntMethod(s_instance._clsInst, s_instance.deleteDir, descriptor, recursive);
    return result;
}

FFIEXPORT
int32_t createFile(int8_t *path, bool recursive) {
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();

    jstring create_path = env->NewStringUTF((char*)path);

    return env->CallIntMethod(s_instance._clsInst, s_instance.createFile, create_path, recursive,
                              true);
}

FFIEXPORT
int32_t renameFile(int32_t descriptor, int8_t *newPath, bool copy) {
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();

    jstring n = env->NewStringUTF((char*)newPath);

    return env->CallIntMethod(s_instance._clsInst, s_instance.renameFile, descriptor, n, copy);
}

FFIEXPORT
int32_t deleteFile(int32_t descriptor) {
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();

    int32_t result = env->CallIntMethod(s_instance._clsInst, s_instance.deleteFile, descriptor);
    return result;
}

FFIEXPORT
int32_t getFileSize(int32_t descriptor) {
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();

    int32_t result = env->CallIntMethod(s_instance._clsInst, s_instance.getFileSize, descriptor);
    return result;
}

//get a error code or fd
FFIEXPORT
int32_t _fopen(int32_t descriptor, int32_t mode) {
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();
    jstring m = env->NewStringUTF(fileModes[mode]);

    return env->CallIntMethod(s_instance._clsInst, s_instance.openFile, descriptor, m);
}

//thread unaware, since fd is share across the process
FFIEXPORT
int32_t _fclose(int32_t fd) {
    return close(fd);
}

FFIEXPORT
int32_t _fread(int32_t fd, int8_t* buf, int32_t count) {
    ssize_t result;
    do { result = read(fd, buf, count); } while (result < 0 && errno == EINTR);
    return result;
}

FFIEXPORT
int32_t  _freadByte(int32_t fd) {
    int8_t b = 0;
    auto count = read(fd, &b, 1);
    return count == 1 ? b : -1;
}

FFIEXPORT
int32_t _fwrite(int32_t fd, int8_t* buf, int32_t count) {
    int32_t written = 0;
    while (written < count) {
        auto result = write(fd, buf + written, count - written);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) return -1;
        written += result;
    }
    return written;
}

FFIEXPORT
int32_t _fwriteByte(int32_t fd, int32_t buf) {
    return write(fd, &buf, 1);
}

FFIEXPORT
int32_t _ftell(int32_t fd) {
    return lseek(fd, 0, SEEK_CUR);
}

FFIEXPORT
int32_t _fseek(int32_t fd, int32_t offset) {
    return lseek(fd, offset, SEEK_SET);
}

FFIEXPORT
int32_t _fflush(int32_t fd) {
    return fdatasync(fd);
}

FFIEXPORT
int32_t _fsize(int32_t fd) {
    struct stat s{};
    auto ret = fstat(fd, &s);
    return ret < 0 ? ret : s.st_size;
}

struct FileContent {
    int8_t * data;
    int32_t size;
};
FFIEXPORT
FileContent* fileReadAllBytes(int32_t descriptor) {
    auto ret = (FileContent*)malloc(sizeof(FileContent));
    ret->data = nullptr;
    ret->size = -1;

    auto file = _fopen(descriptor, 0);
    if(file < 0) {
        return ret;
    }

    std::vector<int8_t> bytes;
    if (!safReadToEnd(file, bytes)) {
        _fclose(file);
        return ret;
    }
    _fclose(file);
    ret->data = static_cast<int8_t*>(malloc(bytes.empty() ? 1 : bytes.size()));
    if (ret->data == nullptr) return ret;
    if (!bytes.empty()) memcpy(ret->data, bytes.data(), bytes.size());
    ret->size = static_cast<int32_t>(bytes.size());
    return ret;
}

FFIEXPORT
int32_t fileWriteAllBytes(int32_t descriptor, int8_t* data, int32_t sizeOfData, int32_t mode) {
    auto file = _fopen(descriptor, mode);
    if(file < 0) {
        return -1;
    }

    auto size = _fwrite(file, data, sizeOfData);

    _fclose(file);
    return size;
}
FFIEXPORT
char* statDoc(int32_t descriptor) {
    ScopedJniEnv scope;
    JNIEnv* env = scope.get();
    auto value = (jstring)env->CallObjectMethod(s_instance._clsInst, s_instance.statDoc, descriptor);
    if (!value) return nullptr;
    const char* bytes = env->GetStringUTFChars(value, nullptr);
    char* result = strdup(bytes);
    env->ReleaseStringUTFChars(value, bytes);
    return result;
}
