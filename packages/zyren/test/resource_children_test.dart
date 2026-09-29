import 'dart:async';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';
import 'resource_scope_test.dart' show Device;

final descriptor = BufferDescriptor(size: 16, usage: {BufferUsage.uniform});

class ReentrantDevice extends Device {
  void Function()? onCreate;
  @override
  Future<Object> createBuffer(BufferDescriptor descriptor) {
    onCreate?.call();
    return super.createBuffer(descriptor);
  }
}

void main() {
  test(
    'child scopes release independently and parent closes every descendant',
    () async {
      final device = Device();
      final parent = ResourceScope(device);
      final first = parent.createChild(label: 'first');
      final second = parent.createChild(label: 'second');
      final nested = second.createChild(label: 'nested');
      final buffer = await first.createBuffer(descriptor);
      await nested.retain(buffer);
      await parent.createBuffer(descriptor);
      await first.close();
      expect(parent.isClosed, isFalse);
      expect(nested.isClosed, isFalse);
      expect(device.live.length, 2);
      await parent.close();
      expect(
        [parent, first, second, nested].every((scope) => scope.isClosed),
        isTrue,
      );
      expect(device.live, isEmpty);
      expect(() => nested.createChild(), throwsStateError);
    },
  );
  test(
    'parent rejects admission throughout the tree while child allocation drains',
    () async {
      final device = Device()..allocating = Completer<Object>();
      final parent = ResourceScope(device);
      final child = parent.createChild();
      final sibling = parent.createChild();
      final pending = child.createBuffer(descriptor);
      final rejected = expectLater(pending, throwsStateError);
      final closing = parent.close();
      expect(child.isClosed && sibling.isClosed, isTrue);
      expect(() => parent.createChild(), throwsStateError);
      expect(device.releases, 0);
      device.allocating!.complete(Object());
      await rejected;
      await closing;
      expect(device.live, isEmpty);
      expect(parent.close(), same(closing));
    },
  );
  test(
    'parent collects child and own cleanup errors without skipping release',
    () async {
      final device = Device();
      final parent = ResourceScope(device);
      await parent.createBuffer(descriptor);
      await parent.createChild().createBuffer(descriptor);
      await parent.createChild().createBuffer(descriptor);
      device.failRelease = true;
      await expectLater(
        parent.close(),
        throwsA(
          isA<ScopeCleanupException>().having(
            (e) => e.errors.length,
            'errors',
            3,
          ),
        ),
      );
      expect(device.releases, 3);
      await parent.whenClosed;
    },
  );
  test(
    'reentrant device close tracks allocation before calling the adapter',
    () async {
      final device = ReentrantDevice()..allocating = Completer<Object>();
      final parent = ResourceScope(device);
      final child = parent.createChild();
      Future<void>? closing;
      device.onCreate = () {
        closing = parent.close();
      };
      final pending = child.createBuffer(descriptor);
      final rejected = expectLater(pending, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      device.allocating!.complete(Object());
      await rejected;
      await closing;
      expect(device.live, isEmpty);
    },
  );
}
