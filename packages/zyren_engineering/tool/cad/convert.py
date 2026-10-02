"""Convert IFC, STEP or IGES into a GLB and a source-identity review sidecar."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import tempfile
import os

import numpy as np

MAX_PARTS = 10000
MAX_TRIANGLES = 2000000
C = np.array([[1., 0., 0., 0.], [0., 0., 1., 0.], [0., -1., 0., 0.], [0., 0., 0., 1.]])


def ifc_parts(path):
    import ifcopenshell
    import ifcopenshell.geom
    source = ifcopenshell.open(str(path))
    settings = ifcopenshell.geom.settings()
    seen = set()
    for product in source.by_type('IfcProduct'):
        if product.Representation is None:
            continue
        key = 'ifc:' + product.GlobalId
        if key in seen:
            raise ValueError('Duplicate IFC GlobalId: ' + product.GlobalId)
        seen.add(key)
        shape = ifcopenshell.geom.create_shape(settings, product)
        vertices = np.asarray(shape.geometry.verts, dtype=float).reshape(-1, 3)
        faces = np.asarray(shape.geometry.faces, dtype=np.uint32).reshape(-1, 3)
        matrix = np.asarray(shape.transformation.matrix, dtype=float).reshape((4, 4), order='F')
        yield key, product.Name or product.is_a(), vertices, faces, matrix, {'format': 'IFC', 'ifcType': product.is_a(), 'sourceId': product.GlobalId}


def occt_parts(path, mapping, meters_per_unit, deflection):
    from OCP.STEPControl import STEPControl_Reader
    from OCP.IGESControl import IGESControl_Reader
    from OCP.IFSelect import IFSelect_RetDone
    from OCP.BRepMesh import BRepMesh_IncrementalMesh
    from OCP.BRep import BRep_Tool
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopAbs import TopAbs_FACE, TopAbs_REVERSED
    from OCP.TopLoc import TopLoc_Location
    from OCP.TopoDS import TopoDS
    is_step = path.suffix.lower() in ('.step', '.stp')
    reader = STEPControl_Reader() if is_step else IGESControl_Reader()
    if reader.ReadFile(str(path)) != IFSelect_RetDone:
        raise ValueError('CAD parser could not read the source file.')
    used = set()
    for root_index in range(1, reader.NbRootsForTransfer() + 1):
        entity = reader.RootForTransfer(root_index)
        if is_step:
            if not hasattr(entity, 'Formation'):
                raise ValueError('STEP root has no product identity. Export named product definitions.')
            selector = 'step:' + entity.Formation().OfProduct().Id().ToCString()
        else:
            if not entity.HasShortLabel():
                raise ValueError('IGES root has no authored label. Supply a labelled export; directory indices are not identities.')
            selector = 'iges:' + entity.ShortLabel().ToCString().rstrip() + ':' + str(entity.SubScriptNumber() if entity.HasSubScriptNumber() else -1)
        if selector in used or selector not in mapping:
            raise ValueError('Missing or duplicate authored source selector: ' + selector)
        used.add(selector)
        record = mapping[selector]
        reader.ClearShapes()
        if not reader.TransferOneRoot(root_index) or reader.NbShapes() != 1:
            raise ValueError('CAD transfer did not produce one root shape: ' + selector)
        shape = reader.Shape(1)
        transform = shape.Location().Transformation()
        matrix = np.eye(4)
        for row in range(3):
            for col in range(4):
                matrix[row, col] = transform.Value(row + 1, col + 1)
        matrix[:3, 3] *= meters_per_unit
        shape = shape.Located(TopLoc_Location())
        mesher = BRepMesh_IncrementalMesh(shape, deflection, False, .35, True)
        if not mesher.IsDone():
            raise ValueError('CAD tessellation failed: ' + selector)
        vertices, faces = [], []
        explorer = TopExp_Explorer(shape, TopAbs_FACE)
        while explorer.More():
            face = TopoDS.Face_s(explorer.Current())
            location = TopLoc_Location()
            mesh = BRep_Tool.Triangulation_s(face, location)
            if mesh is None:
                raise ValueError('A CAD face could not be tessellated: ' + selector)
            offset = len(vertices)
            for i in range(1, mesh.NbNodes() + 1):
                point = mesh.Node(i).Transformed(location.Transformation())
                vertices.append([point.X() * meters_per_unit, point.Y() * meters_per_unit, point.Z() * meters_per_unit])
            for i in range(1, mesh.NbTriangles() + 1):
                a, b, c = mesh.Triangle(i).Get()
                if face.Orientation() == TopAbs_REVERSED:
                    b, c = c, b
                faces.append([offset + a - 1, offset + b - 1, offset + c - 1])
            explorer.Next()
        yield record['id'], record['label'], np.asarray(vertices), np.asarray(faces), matrix, {'format': 'STEP' if is_step else 'IGES', 'sourceId': selector, 'metersPerUnit': meters_per_unit}
    if used != set(mapping):
        raise ValueError('Identity map contains source selectors absent from this export.')


def validate_text(value, label, limit):
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise ValueError(label + ' is invalid.')


def read_mapping(path):
    if path is None:
        raise ValueError('STEP and IGES require --identity-map with authored source selectors.')
    if path.stat().st_size > 2 * 1024 * 1024:
        raise ValueError('Identity map exceeds the size limit.')
    value = json.loads(path.read_text())
    if value.get('schemaVersion') != 1 or not isinstance(value.get('objects'), list):
        raise ValueError('Invalid identity map schema.')
    result, keys = {}, set()
    for record in value['objects']:
        for field, limit in [('selector', 256), ('id', 256), ('label', 240)]:
            validate_text(record.get(field), field, limit)
        if record['selector'] in result or record['id'] in keys:
            raise ValueError('Duplicate source selector or review ID.')
        result[record['selector']] = record
        keys.add(record['id'])
    if not result or len(result) > MAX_PARTS:
        raise ValueError('Invalid identity map part count.')
    return result


def encode(parts):
    root = {'asset': {'version': '2.0', 'generator': 'Zyren engineering CAD converter'},
            'scene': 0, 'scenes': [{'nodes': []}], 'nodes': [], 'meshes': [],
            'materials': [{'pbrMetallicRoughness': {'baseColorFactor': [.37, .66, .82, 1.], 'metallicFactor': .1, 'roughnessFactor': .7}}],
            'buffers': [], 'bufferViews': [], 'accessors': []}
    binary = bytearray()
    entries, keys, total_triangles = [], set(), 0

    def accessor(data, components, kind, component_type, bounds=False):
        while len(binary) % 4:
            binary.append(0)
        offset = len(binary)
        binary.extend(data.tobytes())
        view = len(root['bufferViews'])
        root['bufferViews'].append({'buffer': 0, 'byteOffset': offset, 'byteLength': data.nbytes})
        result = {'bufferView': view, 'componentType': component_type, 'count': int(data.size // components), 'type': kind}
        if bounds:
            result.update(min=data.min(axis=0).tolist(), max=data.max(axis=0).tolist())
        root['accessors'].append(result)
        return len(root['accessors']) - 1

    for key, label, vertices, faces, matrix, properties in parts:
        validate_text(key, 'Source ID', 256)
        validate_text(label, 'Label', 240)
        if key in keys or len(keys) >= MAX_PARTS:
            raise ValueError('Duplicate source ID or part limit exceeded.')
        keys.add(key)
        if len(faces) == 0:
            raise ValueError('Source part has no triangles: ' + key)
        total_triangles += len(faces)
        if total_triangles > MAX_TRIANGLES:
            raise ValueError('Converted model exceeds the triangle limit.')
        positions = np.asarray(vertices @ C[:3, :3].T, dtype='<f4')
        positions = positions[faces].reshape(-1, 3)
        triangle_positions = positions.reshape(-1, 3, 3)
        normals = np.cross(triangle_positions[:, 1] - triangle_positions[:, 0], triangle_positions[:, 2] - triangle_positions[:, 0])
        lengths = np.linalg.norm(normals, axis=1)
        normals = normals / np.where(lengths > 0, lengths, 1)[:, None]
        normals = np.repeat(normals, 3, axis=0).astype('<f4')
        matrix = C @ matrix @ np.linalg.inv(C)
        if not np.isfinite(positions).all() or not np.isfinite(matrix).all():
            raise ValueError('Source contains non-finite coordinates.')
        p = accessor(positions, 3, 'VEC3', 5126, True)
        n = accessor(normals, 3, 'VEC3', 5126)
        i = accessor(np.arange(len(positions), dtype='<u4'), 1, 'SCALAR', 5125)
        index = len(root['nodes'])
        root['meshes'].append({'primitives': [{'attributes': {'POSITION': p, 'NORMAL': n}, 'indices': i, 'material': 0}]})
        root['nodes'].append({'name': label, 'mesh': index, 'matrix': matrix.flatten(order='F').tolist(), 'extras': {'sourceId': key}})
        root['scenes'][0]['nodes'].append(index)
        entries.append({'id': key, 'label': label, 'properties': properties, 'path': [index]})
    if not entries:
        raise ValueError('Source contains no renderable parts.')
    root['buffers'] = [{'byteLength': len(binary)}]
    js = json.dumps(root, separators=(',', ':'), allow_nan=False).encode()
    js += b' ' * (-len(js) % 4)
    binary += b'\0' * (-len(binary) % 4)
    data = struct.pack('<III', 0x46546C67, 2, 28 + len(js) + len(binary))
    data += struct.pack('<II', len(js), 0x4E4F534A) + js + struct.pack('<II', len(binary), 0x004E4942) + binary
    return data, entries


def convert(source, destination, identity_map=None, meters_per_unit=None, deflection=.1):
    source, destination = Path(source), Path(destination)
    if source.stat().st_size > 256 * 1024 * 1024:
        raise ValueError('Source exceeds the 256 MiB limit.')
    extension = source.suffix.lower()
    if extension == '.ifc':
        parts = ifc_parts(source)
    elif extension in ('.step', '.stp', '.iges', '.igs'):
        if meters_per_unit is None or not math.isfinite(meters_per_unit) or meters_per_unit <= 0:
            raise ValueError('STEP and IGES require a positive --meters-per-unit for the transferred model.')
        if not math.isfinite(deflection) or deflection <= 0:
            raise ValueError('Deflection must be positive.')
        parts = occt_parts(source, read_mapping(identity_map), meters_per_unit, deflection)
    else:
        raise ValueError('Supported formats: IFC, STEP and IGES. Convert native vendor files with the vendor exporter first.')
    glb, entries = encode(parts)
    version = hashlib.sha256(glb).hexdigest()
    sidecar = {'schemaVersion': 1, 'modelVersion': version, 'modelSha256': version,
               'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(),
               'sourceFormat': extension[1:], 'entries': entries}
    sidecar_bytes = json.dumps(sidecar, indent=2, allow_nan=False).encode()
    if len(sidecar_bytes) > 2 * 1024 * 1024:
        raise ValueError('Sidecar exceeds the review size limit.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Publish a complete directory. Existing bundles are never partially replaced.
    with tempfile.TemporaryDirectory(prefix='.zyren-cad-', dir=destination.parent) as staging:
        bundle = Path(staging) / 'bundle'
        bundle.mkdir()
        (bundle / 'model.glb').write_bytes(glb)
        (bundle / 'review.json').write_bytes(sidecar_bytes)
        os.rename(bundle, destination)
    return sidecar


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output_bundle', type=Path)
    parser.add_argument('--identity-map', type=Path)
    parser.add_argument('--meters-per-unit', type=float)
    parser.add_argument('--deflection', type=float, default=.1)
    args = parser.parse_args()
    try:
        result = convert(args.source, args.output_bundle, args.identity_map, args.meters_per_unit, args.deflection)
        print(json.dumps({'bundle': str(args.output_bundle), 'modelVersion': result['modelVersion'], 'parts': len(result['entries'])}))
    except Exception as error:
        parser.exit(1, 'Conversion failed: ' + str(error) + '\n')
