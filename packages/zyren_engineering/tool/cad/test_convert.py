import json
from pathlib import Path
import struct
import subprocess
import os
import sys
import tempfile
import unittest

import numpy as np
from convert import convert


def step_fixture(path):
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
    from OCP.STEPControl import STEPControl_Writer, STEPControl_AsIs
    from OCP.StepBasic import StepBasic_Product
    from OCP.TCollection import TCollection_HAsciiString
    writer = STEPControl_Writer()
    writer.Transfer(BRepPrimAPI_MakeBox(10, 20, 30).Shape(), STEPControl_AsIs)
    model = writer.Model()
    for i in range(1, model.NbEntities() + 1):
        entity = model.Value(i)
        if isinstance(entity, StepBasic_Product):
            entity.SetId(TCollection_HAsciiString('PUMP-HOUSING'))
    writer.Write(str(path))


def iges_fixture(path):
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
    from OCP.IGESControl import IGESControl_Writer
    from OCP.IGESBasic import IGESBasic_Group
    from OCP.TCollection import TCollection_HAsciiString
    writer = IGESControl_Writer()
    writer.AddShape(BRepPrimAPI_MakeBox(10, 20, 30).Shape())
    writer.ComputeModel()
    model = writer.Model()
    for i in range(1, model.NbEntities() + 1):
        entity = model.Value(i)
        if isinstance(entity, IGESBasic_Group):
            entity.SetLabel(TCollection_HAsciiString('PUMP'), 7)
    writer.Write(str(path))


def ifc_fixture(path, moved=False):
    import ifcopenshell
    import ifcopenshell.api.root
    import ifcopenshell.api.context
    import ifcopenshell.api.unit
    import ifcopenshell.api.geometry
    model = ifcopenshell.file(schema='IFC4')
    ifcopenshell.api.root.create_entity(model, ifc_class='IfcProject', name='Review fixture')
    ifcopenshell.api.unit.assign_unit(model)
    context = ifcopenshell.api.context.add_context(model, context_type='Model')
    body = ifcopenshell.api.context.add_context(model, context_type='Model', context_identifier='Body', target_view='MODEL_VIEW', parent=context)
    wall = ifcopenshell.api.root.create_entity(model, ifc_class='IfcWall', name='Housing renamed' if moved else 'Housing')
    wall.GlobalId = '0J$yPqHBD2TQczIzCWzDNN'
    representation = ifcopenshell.api.geometry.add_wall_representation(model, context=body, length=1., height=.7, thickness=.25)
    ifcopenshell.api.geometry.assign_representation(model, product=wall, representation=representation)
    matrix = np.eye(4)
    matrix[0, 3] = 3 if moved else 0
    ifcopenshell.api.geometry.edit_object_placement(model, product=wall, matrix=matrix)
    model.write(str(path))


class ConvertTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zyren-cad-test-')
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def gltf(self, bundle):
        data = (bundle / 'model.glb').read_bytes()
        magic, version, length = struct.unpack_from('<III', data)
        self.assertEqual((magic, version, length), (0x46546C67, 2, len(data)))
        json_length = struct.unpack_from('<I', data, 12)[0]
        return json.loads(data[20:20 + json_length])

    def test_step_and_iges_use_authored_keys_and_real_tessellation(self):
        for suffix, fixture, selector in [('step', step_fixture, 'step:PUMP-HOUSING'), ('iges', iges_fixture, 'iges:PUMP:7')]:
            source = self.root / ('part.' + suffix)
            fixture(source)
            mapping = self.root / (suffix + '.json')
            mapping.write_text(json.dumps({'schemaVersion': 1, 'objects': [
                {'selector': selector, 'id': 'source:part-1', 'label': 'Housing'}]}))
            bundle = self.root / (suffix + '-bundle')
            sidecar = convert(source, bundle, mapping, .001)
            self.assertEqual(sidecar['entries'][0]['id'], 'source:part-1')
            self.assertEqual(sidecar['entries'][0]['path'], [0])
            mesh = self.gltf(bundle)
            self.assertGreaterEqual(mesh['accessors'][0]['count'], 36)
            self.assertAlmostEqual(mesh['accessors'][0]['max'][0], .01, places=6)
            with self.assertRaises(ValueError):
                convert(source, self.root / ('missing-' + suffix), None, .001)

    def test_ifc_global_id_survives_rename_and_placement_change(self):
        if not os.environ.get('ZYREN_IFC_TEST_CHILD'):
            result = subprocess.run([sys.executable, '-m', 'unittest', 'test_convert.ConvertTest.test_ifc_global_id_survives_rename_and_placement_change'],
                cwd=Path(__file__).parent, env={**os.environ, 'ZYREN_IFC_TEST_CHILD': '1'}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return
        first, second = self.root / 'first.ifc', self.root / 'second.ifc'
        ifc_fixture(first)
        ifc_fixture(second, moved=True)
        a = convert(first, self.root / 'a')
        b = convert(second, self.root / 'b')
        self.assertEqual(a['entries'][0]['id'], b['entries'][0]['id'])
        self.assertNotEqual(a['modelVersion'], b['modelVersion'])
        self.assertEqual(self.gltf(self.root / 'b')['nodes'][0]['matrix'][12], 3)
        self.assertEqual(self.gltf(self.root / 'a')['accessors'][0]['min'], self.gltf(self.root / 'b')['accessors'][0]['min'])
        with self.assertRaises(OSError):
            convert(second, self.root / 'a')
        self.assertEqual(json.loads((self.root / 'a' / 'review.json').read_text())['modelVersion'], a['modelVersion'])

    def test_rejects_unmapped_source_and_vendor_formats(self):
        source = self.root / 'part.step'
        step_fixture(source)
        mapping = self.root / 'bad.json'
        mapping.write_text(json.dumps({'schemaVersion': 1, 'objects': [{'selector': 'step:wrong', 'id': 'part', 'label': 'Part'}]}))
        with self.assertRaises(ValueError):
            convert(source, self.root / 'bad', mapping, .001)
        self.assertFalse((self.root / 'bad').exists())
        vendor = self.root / 'part.sldprt'
        vendor.write_bytes(b'not a parsed CAD file')
        with self.assertRaises(ValueError):
            convert(vendor, self.root / 'vendor')


if __name__ == '__main__':
    unittest.main()
