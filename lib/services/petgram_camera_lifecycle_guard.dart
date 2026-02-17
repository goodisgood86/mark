class PetgramCameraLifecycleGuard {
  PetgramCameraLifecycleGuard._();

  static int _lockCount = 0;
  static int _authFlowCount = 0;

  static bool get suppressed => _lockCount > 0;
  static bool get authFlowInProgress => _authFlowCount > 0;

  static void acquire() {
    _lockCount++;
  }

  static void release() {
    if (_lockCount > 0) {
      _lockCount--;
    }
  }

  static void beginAuthFlow() {
    _authFlowCount++;
  }

  static void endAuthFlow() {
    if (_authFlowCount > 0) {
      _authFlowCount--;
    }
  }
}
