import 'dart:async';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

class Device implements ResourceDevice {
  final live = <Object, int>{};
  final writes = <Uint8List>[];
  Completer<Object>? allocating;
  Completer<void>? writing;
  bool failRelease = false;
  int releases = 0;
  @override
  Future<Object> createBuffer(BufferDescriptor descriptor) async {
    final key = await (allocating?.future ?? Future.value(Object()));
    live[key] = 1;
    return key;
  }

  @override
  Future<Object> createTexture(TextureDescriptor descriptor) => createBuffer(
    BufferDescriptor(size: 4, usage: {BufferUsage.copyDestination}),
  );
  @override
  Future<void> retain(Object key) async => live[key] = live[key]! + 1;
  @override
  Future<void> release(Object key) async {
    releases++;
    if (failRelease) throw StateError("release failure");
    final count = live[key]! - 1;
    if (count == 0) {
      live.remove(key);
    } else {
      live[key] = count;
    }
  }

  @override
  Future<void> writeBuffer(Object key, int offset, Uint8List bytes) async {
    await (writing?.future ?? Future<void>.delayed(Duration.zero));
    writes.add(bytes);
  }

  @override
  Future<void> writeTexture(Object key, int mipLevel, Uint8List bytes) async {}
  @override
  Future<void> generateMipmaps(
    Object key,
    MipmapAlphaFilter alphaFilter,
  ) async {
    await writing?.future;
  }

  @override
  Future<Uint8List> readTexture(Object key, int mipLevel) async => Uint8List(4);
  @override
  Future<Uint8List> readBuffer(Object key, int offset, int length) async =>
      Uint8List(length);
}

void main() {
  test(
    'mip generation drains before release and checks scope ownership',
    () async {
      final device = Device()..writing = Completer<void>();
      final owner = ResourceScope(device), other = ResourceScope(device);
      final texture = await owner.createTexture(
        TextureDescriptor(
          width: 2,
          height: 2,
          mipLevels: 2,
          usage: {TextureUsage.sampled, TextureUsage.renderAttachment},
        ),
      );
      await expectLater(other.generateMipmaps(texture), throwsArgumentError);
      final pending = owner.generateMipmaps(
        texture,
        alphaFilter: MipmapAlphaFilter.weighted,
      );
      final closing = owner.close();
      await Future<void>.delayed(Duration.zero);
      expect(device.releases, 0);
      device.writing!.complete();
      await pending;
      await closing;
      expect(device.live, isEmpty);
      await expectLater(owner.generateMipmaps(texture), throwsStateError);
      await other.close();
    },
  );
  BufferDescriptor descriptor() => BufferDescriptor(
    label: 'vertices',
    size: 16,
    usage: {
      BufferUsage.vertex,
      BufferUsage.copyDestination,
      BufferUsage.copySource,
    },
  );
  test('scope sharing retains resources until the last owner closes', () async {
    final device = Device();
    final first = ResourceScope(device), second = ResourceScope(device);
    final buffer = await first.createBuffer(descriptor());
    final shared = await second.retain(buffer);
    expect(buffer.label, 'vertices');
    await first.close();
    expect(device.live.values, [1]);
    await second.writeBuffer(shared, Uint8List(4));
    await expectLater(
      second.writeBuffer(buffer, Uint8List(4)),
      throwsStateError,
    );
    await second.close();
    await second.close();
    expect(device.live, isEmpty);
  });
  test('close drains allocation races and forbids new work', () async {
    final device = Device()..allocating = Completer<Object>();
    final scope = ResourceScope(device);
    final pending = scope.createBuffer(descriptor());
    final rejected = expectLater(pending, throwsStateError);
    final closing = scope.close();
    await expectLater(scope.createBuffer(descriptor()), throwsStateError);
    device.allocating!.complete(Object());
    await rejected;
    await closing;
    expect(device.live, isEmpty);
  });
  test('foreign device and foreign scope fail before the driver', () async {
    final device = Device();
    final first = ResourceScope(device), sibling = ResourceScope(device);
    final other = ResourceScope(Device());
    final buffer = await first.createBuffer(descriptor());
    await expectLater(other.retain(buffer), throwsArgumentError);
    await expectLater(
      sibling.writeBuffer(buffer, Uint8List(4)),
      throwsArgumentError,
    );
    await first.close();
    await sibling.close();
    await other.close();
  });
  test('uploads capture typed data before asynchronous transfer', () async {
    final device = Device();
    final scope = ResourceScope(device);
    final buffer = await scope.createBuffer(descriptor());
    final source = Uint8List.fromList([1, 2, 3, 4]);
    final writing = scope.writeBuffer(buffer, source);
    source.fillRange(0, 4, 99);
    await writing;
    expect(device.writes.single, [1, 2, 3, 4]);
    await expectLater(
      scope.writeBuffer(buffer, Uint8List(8), offset: 12),
      throwsRangeError,
    );
    await expectLater(
      scope.writeBuffer(buffer, Uint8List(4), offset: 1),
      throwsArgumentError,
    );
    await scope.close();
  });
  test('descriptors validate size, usage and mip extents', () {
    expect(
      () => BufferDescriptor(size: 0, usage: {BufferUsage.vertex}),
      throwsArgumentError,
    );
    expect(() => BufferDescriptor(size: 16, usage: {}), throwsArgumentError);
    expect(
      () => TextureDescriptor(width: 2, height: 2, mipLevels: 3),
      throwsArgumentError,
    );
    final texture = TextureDescriptor(width: 3, height: 5, mipLevels: 3);
    expect(texture.byteLength, (3 * 5 + 1 * 2 + 1) * 4);
    final usage = {BufferUsage.vertex};
    final buffer = BufferDescriptor(size: 4, usage: usage);
    usage.clear();
    expect(buffer.usage, {BufferUsage.vertex});
  });
  test(
    'close waits for accepted writes and attempts every release after errors',
    () async {
      final device = Device()..writing = Completer<void>();
      final scope = ResourceScope(device);
      final buffer = await scope.createBuffer(descriptor());
      await scope.createBuffer(descriptor());
      final write = scope.writeBuffer(buffer, Uint8List(4));
      device.failRelease = true;
      final closing = scope.close();
      final failed = expectLater(
        closing,
        throwsA(isA<ScopeCleanupException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(device.releases, 0);
      device.writing!.complete();
      await write;
      await failed;
      await scope.whenClosed;
      expect(device.releases, 2);
      expect(identical(closing, scope.close()), isTrue);
    },
  );
  test('a typed-data slice uploads only its visible bytes', () async {
    final device = Device();
    final owner = ResourceScope(device);
    final buffer = await owner.createBuffer(descriptor());
    final storage = Uint8List.fromList([90, 91, 1, 2, 3, 4, 92]);
    await owner.writeBuffer(buffer, Uint8List.sublistView(storage, 2, 6));
    expect(device.writes.single, [1, 2, 3, 4]);
    await owner.close();
  });
  test(
    'texture upload validates one complete mip and declared usage',
    () async {
      final scope = ResourceScope(Device());
      final texture = await scope.createTexture(
        TextureDescriptor(width: 3, height: 5, mipLevels: 3),
      );
      await expectLater(
        scope.writeTexture(texture, Uint8List(4)),
        throwsArgumentError,
      );
      await expectLater(
        scope.writeTexture(texture, Uint8List(4), mipLevel: 3),
        throwsRangeError,
      );
      await expectLater(scope.readTexture(texture), throwsArgumentError);
      await scope.writeTexture(texture, Uint8List(4), mipLevel: 2);
      await scope.close();
    },
  );
}
