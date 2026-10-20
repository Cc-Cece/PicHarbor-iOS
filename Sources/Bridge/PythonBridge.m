#define PY_SSIZE_T_CLEAN
#include <Python/Python.h>
#import "PythonBridge.h"

// Interpreter is initialized/imported on the main thread (gpmc installs SIGINT).
// Calls use separate native threads; the GIL protects Python execution while
// requests releases it for I/O. Progress handlers must be thread-local too.
static PyObject *dispatchFunction;
static PyObject *cancelFunction;
static NSString * const progressKey = @"PicHarborPythonProgress";

static PyObject *emitEvent(PyObject *self, PyObject *args) {
    const char *value;
    if (!PyArg_ParseTuple(args, "s", &value)) return NULL;
    void (^handler)(NSString *) = [NSThread currentThread].threadDictionary[progressKey];
    if (handler) handler([NSString stringWithUTF8String:value]);
    Py_RETURN_NONE;
}
static PyMethodDef methods[] = {{"event", emitEvent, METH_VARARGS, NULL}, {NULL, NULL, 0, NULL}};
static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "_harbor_native", NULL, -1, methods};
static PyObject *PyInit_harbor_native(void) { return PyModule_Create(&module); }

@implementation PythonBridge
+ (BOOL)start:(NSString *)home {
    NSAssert([NSThread isMainThread], @"Initialize Python on main thread");
    if (dispatchFunction) return YES;
    if (Py_IsInitialized()) return NO;
    if (PyImport_AppendInittab("_harbor_native", PyInit_harbor_native) == -1) return NO;
    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSString *pythonHome = [resources stringByAppendingPathComponent:@"python"];
    NSString *paths = [NSString stringWithFormat:@"%@/app:%@/python/lib/python3.13:%@/python/lib/python3.13/lib-dynload", resources, resources, resources];
    setenv("PYTHONHOME", pythonHome.UTF8String, 1);
    setenv("PYTHONPATH", paths.UTF8String, 1);
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    setenv("PYTHONNOUSERSITE", "1", 1);
    PyPreConfig preconfig;
    PyPreConfig_InitPythonConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) return NO;
    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.parse_argv = 0;
    config.write_bytecode = 0;
    config.buffered_stdio = 0;
    config.install_signal_handlers = 1;
    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) return NO;
    PyObject *adapter = PyImport_ImportModule("harbor_ios");
    if (adapter) {
        PyObject *init = PyObject_CallMethod(adapter, "initialize", "s", home.UTF8String);
        if (init) dispatchFunction = PyObject_GetAttrString(adapter, "dispatch");
        if (init) cancelFunction = PyObject_GetAttrString(adapter, "cancel_request");
        Py_XDECREF(init);
        Py_DECREF(adapter);
    }
    // Clear exceptions without printing sensitive Python tracebacks.
    BOOL ready = dispatchFunction && PyCallable_Check(dispatchFunction);
    PyErr_Clear();
    PyEval_SaveThread();
    return ready;
}
+ (void)cancelRequest:(NSString *)requestID reason:(NSString *)reason {
    if (!cancelFunction) return;
    PyGILState_STATE state = PyGILState_Ensure();
    PyObject *result = PyObject_CallFunction(cancelFunction, "ss", requestID.UTF8String, reason.UTF8String);
    Py_XDECREF(result); PyErr_Clear();
    PyGILState_Release(state);
}
+ (NSString *)call:(NSString *)action payload:(NSString *)payload event:(void (^)(NSString *))event {
    if (!dispatchFunction) return @"{\"ok\":false,\"error\":\"RUNTIME_UNAVAILABLE\"}";
    PyGILState_STATE state = PyGILState_Ensure();
    if (event) [NSThread currentThread].threadDictionary[progressKey] = [event copy];
    PyObject *result = PyObject_CallFunction(dispatchFunction, "ss", action.UTF8String, payload.UTF8String);
    const char *utf8 = result ? PyUnicode_AsUTF8(result) : NULL;
    NSString *text = utf8 ? [NSString stringWithUTF8String:utf8] : @"{\"ok\":false,\"error\":\"ENGINE_ERROR\"}";
    Py_XDECREF(result);
    PyErr_Clear();
    [[NSThread currentThread].threadDictionary removeObjectForKey:progressKey];
    PyGILState_Release(state);
    return text;
}
@end
