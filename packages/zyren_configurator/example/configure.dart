import 'package:zyren/zyren.dart';
import 'package:zyren_configurator/zyren_configurator.dart';

void main() {
  final body = Mesh(BoxGeometry(), UnlitMaterial());
  final accessory = Group();
  final catalog = ConfigurationCatalog(
    id: 'chair',
    revision: 1,
    slots: [
      ConfigurationSlot(
        id: 'finish',
        options: [
          ConfigurationOption(id: 'red', materials: {'body': 'red-paint'}),
          ConfigurationOption(id: 'natural'),
        ],
      ),
      ConfigurationSlot(
        id: 'accessory',
        options: [
          ConfigurationOption(id: 'included', visibility: {'accessory': true}),
          ConfigurationOption(id: 'hidden', visibility: {'accessory': false}),
        ],
      ),
    ],
  );
  final controller = SceneConfigurator(
    catalog: catalog,
    targets: {'body': body, 'accessory': accessory},
    materials: {'red-paint': UnlitMaterial(color: const Color3(1, 0, 0))},
  );
  controller.apply(catalog.select({'finish': 'red', 'accessory': 'hidden'}));
  final saved = controller.current!.encode();
  controller.reset();
  controller.restore(saved);
  print(saved);
  controller.close();
}
