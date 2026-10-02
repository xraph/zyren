import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/rendering.dart';

void main() {
  test('memory reports preserve scope, estimates and an exceeded budget', () {
    const original = GpuMemoryReport(
      status: 'available',
      source: 'vulkan.EXT_memory_budget',
      scope: 'processHeap',
      region: 'heap',
      heapIndex: 1,
      deviceLocal: true,
      usageBytes: 300,
      budgetBytes: 200,
      usageIsEstimate: true,
      budgetIsEstimate: true,
    );
    final copy = GpuMemoryReport.fromJson(
      jsonDecode(jsonEncode(original.toJson())),
    );
    expect(copy.toJson(), original.toJson());
    expect(copy.usageBytes, greaterThan(copy.budgetBytes!));
    expect(copy.recommendedMaxWorkingSetBytes, isNull);
    expect(copy.nodeIndex, isNull);
    expect(copy.unifiedMemory, isNull);
  });

  test('zero, unsupported and query errors remain distinct', () {
    for (final status in ['available', 'unsupported', 'error']) {
      final original = GpuMemoryReport(
        status: status,
        source: 'dxgi.QueryVideoMemoryInfo',
        scope: 'processAdapterSegment',
        region: 'nonLocal',
        nodeIndex: 0,
        usageBytes: status == 'available' ? 0 : null,
        budgetBytes: status == 'available' ? 0 : null,
        reason: status == 'available' ? null : 'queryUnavailable',
      );
      final copy = GpuMemoryReport.fromJson(original.toJson());
      expect(copy.toJson(), original.toJson());
      expect(copy.usageBytes, status == 'available' ? 0 : null);
      expect(copy.budgetBytes, status == 'available' ? 0 : null);
    }
  });

  test('inspection snapshots own immutable memory reports', () {
    final reports = <GpuMemoryReport>[
      const GpuMemoryReport(
        status: 'available',
        source: 'metal.deviceMemory',
        scope: 'processDevice',
        region: 'device',
        usageBytes: 200,
        recommendedMaxWorkingSetBytes: 100,
        unifiedMemory: true,
      ),
    ];
    final snapshot = GpuInspection(
      memoryReports: reports,
      deviceAllocationSource: 'unavailable',
      registryPayloadBytes: 0,
      totalAllocations: 0,
      allocations: [],
    );
    reports.clear();
    expect(snapshot.memoryReports, hasLength(1));
    expect(() => snapshot.memoryReports.clear(), throwsUnsupportedError);
    expect(snapshot.memoryReports.single.budgetBytes, isNull);
    expect(snapshot.residentBytes, isNull);
    expect(snapshot.toJson()['memoryReports'], [
      snapshot.memoryReports.single.toJson(),
    ]);
  });
}
