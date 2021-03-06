// Copyright (c) 2015, the Dartino project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library immic.plugins.dart;

import 'dart:core' hide Type;
import 'dart:io' show Platform, File;

import 'package:path/path.dart' show withoutExtension, join, dirname;
import 'package:strings/strings.dart' as strings;

import 'shared.dart';
import '../emitter.dart';
import '../struct_layout.dart';
import '../primitives.dart' as primitives;

const List<String> RESOURCES = const [
  "immi.dart",
];

const COPYRIGHT = """
// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.
""";

void generate(String path,
              Map<String, Unit> units,
              String outputDirectory) {
  String directory = join(outputDirectory, 'dart');
  units.forEach((path, unit) => _generateNodeFile(path, unit, directory));
  _generateServiceFile(path, units, directory);

  String resourcesDirectory = join(dirname(Platform.script.path),
      '..', 'lib', 'src', 'resources', 'dart');
  for (String resource in RESOURCES) {
    String resourcePath = join(resourcesDirectory, resource);
    File file = new File(resourcePath);
    String contents = file.readAsStringSync();
    writeToFile(directory, resource, contents);
  }
}

String generateNodeString(String unitPath, Unit unit) {
  _DartVisitor visitor = new _DartVisitor(unitPath);
  visitor.visit(unit);
  return visitor.buffer.toString();
}

String generateServiceString(String path, Map units) {
  _DartVisitor visitor = new _DartVisitor(path);
  units.values.forEach(visitor.collectMethodSignatures);
  visitor._writeServiceImpl();
  return visitor.buffer.toString();
}

void _generateNodeFile(String unitPath, Unit unit, String directory) {
  String content = generateNodeString(unitPath, unit);
  writeToFile(directory, unitPath, content, extension: 'dart');
}

void _generateServiceFile(String path,
                          Map<String, Unit> units,
                          String directory) {
  _DartVisitor visitor = new _DartVisitor(path);
  String content = generateServiceString(path, units);
  String file = visitor.serviceImplFile;
  writeToFile(directory, file, content, extension: 'dart');
}

class _DartVisitor extends CodeGenerationVisitor {
  _DartVisitor(String path) : super(path);

  visitUnit(Unit node) {
    _writeHeader();
    _writeLibrary();
    _writeImports();
    node.imports.forEach(visit);
    if (node.imports.isNotEmpty) writeln();
    node.structs.forEach(visit);
  }

  visitImport(Import import) {
    writeln("import '${withoutExtension(import.import)}.dart';");
  }

  getPatchType(Type type) {
    if (type.isList) return 'ListPatch';
    if (type.isNode) return 'NodePatch';
    if (type.resolved != null) return '${type.identifier}Patch';
    return _types[type.identifier];
  }

  getSerializeMethodName(Type type) {
    if (type.isList) return 'serializeList';
    if (type.isNode) return 'serializeNode';
    if (type.resolved != null) return 'serialize${type.identifier}';
    throw 'Unserializable type ${type.identifier}';
  }

  visitStruct(Struct node) {
    String nodeName = '${node.name}Node';
    String patchName = '${node.name}Patch';
    String replacePatch = '${node.name}ReplacePatch';
    String updatePatch = '${node.name}UpdatePatch';
    String nodeBuilderName = '${node.name}NodeDataBuilder';
    String patchBuilderName = '${node.name}PatchDataBuilder';
    String updateBuilderName = '${node.name}UpdateDataBuilder';

    bool hasFields = node.layout.slots.isNotEmpty;
    bool hasMethods = node.methods.isNotEmpty;
    bool hasSlotsAndMethods = hasFields && hasMethods;

    writeln('class $nodeName extends Node {');
    // Final fields.
    forEachSlot(node, null, (Type slotType, String slotName) {
      write('  final ');
      writeType(slotType);
      writeln(' $slotName;');
    });
    for (var method in node.methods) {
      writeln('  final Function ${method.name};');
    }
    // Public keyword constructor.
    if (hasFields || hasMethods) {
      write('  factory $nodeName({');
      forEachSlot(node, writeComma, (Type slotType, String slotName) {
        writeType(slotType);
        write(' $slotName');
      });
      if (hasSlotsAndMethods) write(', ');
      write(node.methods.map((method) => 'Function ${method.name}').join(', '));
      writeln('}) =>');
      write('      new ${nodeName}._internal(');
      forEachSlot(node, writeComma, (_, String slotName) {
        write('$slotName');
      });
      if (hasSlotsAndMethods) write(', ');
      write(node.methods.map((method) => method.name).join(', '));
      writeln(');');
      // Positional constructor.
      write('  ${nodeName}._internal(');
      forEachSlot(node, writeComma, (_, String slotName) {
        write('this.${slotName}');
      });
      if (hasSlotsAndMethods) write(', ');
      write(node.methods.map((method) => 'this.${method.name}').join(', '));
      writeln(');');
    }

    // Serialization
    String serializeSelf = 'serialize${node.name}';
    writeln('  void serializeNode(NodeDataBuilder builder, ResourceManager manager) {');
    writeln('    $serializeSelf(builder.init${node.name}(), manager);');
    writeln('  }');
    writeln('  void $serializeSelf(${nodeName}DataBuilder builder, ResourceManager manager) {');
    forEachSlot(node, null, (Type slotType, String slotName) {
      String slotNameCamel = camelize(slotName);
      if (slotType.isList) {
        String localSlotLength = "${slotName}Length";
        String localSlotBuilder = "${slotName}Builder";
        // TODO(zerny): Support list of primitives.
        String serialize = slotType.elementType.isNode ?
                           'serializeNode' :
                           'serialize${slotType.elementType.identifier}';
        writeln('    var $localSlotLength = $slotName.length;');
        writeln('    List $localSlotBuilder =');
        writeln('        builder.init$slotNameCamel($localSlotLength);');
        writeln('    for (var i = 0; i < $localSlotLength; ++i) {');
        writeln('      $slotName[i].$serialize($localSlotBuilder[i], manager);');
        writeln('    }');
      } else if (slotType.isNode || slotType.resolved != null) {
        String serialize = getSerializeMethodName(slotType);
        writeln('    $slotName.$serialize(builder.init$slotNameCamel(), manager);');
      } else {
        writeln('    builder.$slotName = $slotName;');
      }
    });
    for (var method in node.methods) {
      String methodName = method.name;
      writeln('    builder.$methodName = manager.addHandler($methodName);');
    }
    writeln('  }');

    // Event handlers
    writeln('  void unregisterHandlers(ResourceManager manager) {');
    for (var method in node.methods) {
      writeln('    manager.removeHandler(${method.name});');
    }
    writeln('  }');

    // Difference.
    writeln('  ${node.name}Patch diff(Node previousNode) {');
    if (!hasFields && !hasMethods) {
      writeln('    if (previousNode is $nodeName) return null;');
      writeln('    return new $replacePatch(this, previousNode);');
    } else {
      writeln('    if (identical(this, previousNode)) return null;');
      writeln('    if (previousNode is! $nodeName) {');
      writeln('      return new $replacePatch(this, previousNode);');
      writeln('    }');
      writeln('    $nodeName previous = previousNode;');
      writeln('    $updatePatch updates = null;');
      String ensureUpdatePatch =
          'if (updates == null) updates = new $updatePatch(previous);';
      forEachSlot(node, null, (Type slotType, String slotName) {
        if (slotType.isList) {
          // TODO(zerny): Support lists of primitives.
          String type = slotType.elementType.isNode ?
                        'ListPatchType.AnyNode' :
                        'ListPatchType.SpecificNode';
          writeln('    ${getPatchType(slotType)} ${slotName}Patch =');
          writeln('        diffList($slotName, previous.$slotName, $type);');
          writeln('    if (${slotName}Patch != null) {');
          writeln('      $ensureUpdatePatch');
          writeln('      updates.$slotName = ${slotName}Patch;');
          writeln('    }');
        } else if (slotType.isNode || slotType.resolved != null) {
          writeln('    ${getPatchType(slotType)} ${slotName}Patch =');
          writeln('        $slotName.diff(previous.$slotName);');
          writeln('    if (${slotName}Patch != null) {');
          writeln('      $ensureUpdatePatch');
          writeln('      updates.$slotName = ${slotName}Patch;');
          writeln('    }');
        } else {
          writeln('    if ($slotName != previous.$slotName) {');
          writeln('      $ensureUpdatePatch');
          writeln('      updates.$slotName = $slotName;');
          writeln('    }');
        }
      });
      for (Method method in node.methods) {
        String name = method.name;
        writeln('    if ($name != previous.$name) {');
        writeln('      $ensureUpdatePatch');
        writeln('      updates.$name = $name;');
        writeln('    }');
      }
      writeln('    return updates;');
    }
    writeln('  }');
    // Difference end.

    writeln('}');
    writeln();
    // Node class end.

    // Node specific patches.
    String serializeSelfNode = 'serialize${node.name}';
    String serializeSelfPatch = 'serialize${node.name}';
    writeln('abstract class $patchName extends NodePatch {');
    writeln('  void serializeNode(NodePatchDataBuilder builder, ResourceManager manager) {');
    writeln('    $serializeSelfPatch(builder.init${node.name}(), manager);');
    writeln('  }');
    writeln('  void $serializeSelfPatch($patchBuilderName builder, ResourceManager manager);');
    writeln('}');
    writeln();
    writeln('class $replacePatch extends $patchName {');
    writeln('  final $nodeName replacement;');
    writeln('  final Node previous;');
    writeln('  $replacePatch(this.replacement, this.previous);');
    writeln('  void $serializeSelfPatch($patchBuilderName builder, ResourceManager manager) {');
    writeln('    if (previous != null) previous.unregisterHandlers(manager);');
    writeln('    replacement.$serializeSelfNode(builder.initReplace(), manager);');
    writeln('  }');
    writeln('}');
    writeln();
    if (hasFields || hasMethods) {
      writeln('class $updatePatch extends $patchName {');
      writeln('  final $nodeName previous;');
      writeln('  $updatePatch(this.previous);');
      writeln('  int _count = 0;');
      forEachSlot(node, null, (Type slotType, String slotName) {
        writeln('  ${getPatchType(slotType)} _$slotName;');
        writeln('  set $slotName(${getPatchType(slotType)} $slotName) {');
        writeln('    ++_count;');
        writeln('    _$slotName = $slotName;');
        writeln('  }');
      });
      for (Method method in node.methods) {
        String name = method.name;
        writeln('  Function _$name;');
        writeln('  set $name(Function $name) {');
        writeln('    ++_count;');
        writeln('    _$name = $name;');
        writeln('  }');
      }
      writeln('  void $serializeSelfPatch($patchBuilderName builder, ResourceManager manager) {');
      writeln('    List<${updateBuilderName}> builders = builder.initUpdates(_count);');
      writeln('    int index = 0;');
      forEachSlot(node, null, (Type slotType, String slotName) {
        writeln('    if (_$slotName != null) {');
        if (slotType.isList || slotType.isNode || slotType.resolved != null) {
          String slotNameCamel = camelize(slotName);
          String serializeSlot = getSerializeMethodName(slotType);
          writeln('      _$slotName.$serializeSlot(builders[index++].init$slotNameCamel(), manager);');
        } else {
          writeln('      builders[index++].$slotName = _$slotName;');
        }
        writeln('    }');
      });
      for (Method method in node.methods) {
        String name = method.name;
        writeln('    if (_$name != null) {');
        writeln('      manager.removeHandler(previous.$name);');
        writeln('      builders[index++].$name = manager.addHandler(_$name);');
        writeln('    }');
      }
      writeln('    assert(index == _count);');
      writeln('  }');
      writeln('}');
      writeln();
    }
  }

  visitUnion(Union node) {
    // Ignored for now.
  }

  visitMethod(Method node) {
    // Ignored for now.
  }

  void _writeServiceImpl() {
    _writeHeader();
    write("""
library ${serviceImplLib};

import '${immiGenPkg}/dart/immi.dart';
import '${serviceGenPkg}/dart/${serviceFile}.dart';

class ${serviceImplName} extends ${serviceName} {
  var _nextPresenterId = 1;
  var _presenters = [null];
  var _presenterGraphs = [null];
  var _presenterNameToId = {};

  // TODO(zerny): Implement per-graph resource management.
  ResourceManager _manager = new ResourceManager();

  ${serviceImplName}();
  void add(String name, presenter) {
    assert(!_presenterNameToId.containsKey(name));
    _presenterNameToId[name] = _addPresenter(presenter);
  }

  int _addPresenter(presenter) {
    assert(_presenters.length == _nextPresenterId);
    assert(_presenterGraphs.length == _nextPresenterId);
    _presenters.add(presenter);
    _presenterGraphs.add(null);
    return _nextPresenterId++;
  }

  int getPresenter(PresenterData data) {
    String name = data.name;
    int pid = _presenterNameToId[name];
    return pid == null ? 0 : pid;
  }

  void reset(int pid) {
    int length = _presenterGraphs.length;
    for (int i = 0; i < length; ++i) {
      _presenterGraphs[i] = null;
    }
    _manager.clear();
  }

  void refresh(int pid, PatchDataBuilder builder) {
    assert(0 < pid && pid < _nextPresenterId);
    Node previous = _presenterGraphs[pid];
    Node current = _presenters[pid].present(previous);
    NodePatch patch = current.diff(previous);
    if (patch == null) {
      builder.setNoPatch();
    } else {
      _presenterGraphs[pid] = current;
      patch.serializeNode(builder.initNode(), _manager);
    }
  }

  void run() {
    ${serviceName}.initialize(this);
    while (${serviceName}.hasNextEvent()) {
      ${serviceName}.handleNextEvent();
    }
  }

""");
    for (List<Type> formals in methodSignatures.values) {
      String suffix = actionTypeSuffix(formals);
      bool boxedArguments = formals.any((t) => t.isString);
      if (boxedArguments) {
        writeln('  void dispatch$suffix(Action${suffix}Args args) {');
        writeln('    var handler = _manager.getHandler(args.id);');
        writeln('    if (handler != null) handler(');
        for (int j = 0; j <= formals.length - 1; ++j) {
          if (j != 0) write(',');
          write('args.arg$j');
        }
        writeln(');');
        writeln('  }');
        continue;
      }
      write('  void dispatch$suffix(int id');
      int i = 0;
      for (var formal in formals) {
        write(', ');
        writeType(formal);
        write(' arg${i++}');
      }
      writeln(') {');
      writeln('    var handler = _manager.getHandler(id);');
      write('    if (handler != null) handler(');
      for (int j = 0; j <= i - 1; ++j) {
        if (j != 0) write(', ');
        write('arg$j');
      }
      writeln(');');

      writeln('  }');
      writeln();
    }
    writeln('}');
    writeln();
  }

  void _writeHeader() {
    writeln(COPYRIGHT);
    writeln('// Generated file. Do not edit.');
    writeln();
  }

  void _writeLibrary() {
    writeln('library $libraryName;');
    writeln();
  }

  void _writeImports() {
    writeln('import "$immiGenPkg/dart/immi.dart";');
    writeln('import "$serviceGenPkg/dart/$serviceFile.dart";');
    writeln();
  }

  static const Map<String, String> _types = const {
    'void'    : 'void',
    'bool'    : 'bool',

    'uint8'   : 'int',
    'uint16'  : 'int',

    'int8'    : 'int',
    'int16'   : 'int',
    'int32'   : 'int',
    'int64'   : 'int',

    'float32' : 'double',
    'float64' : 'double',

    'String'  : 'String',
  };

  void writeType(Type node) {
    if (node.isList) write('List<');
    if (node.isNode || (node.isList && node.elementType.isNode)) {
      write('Node');
    } else if (node.resolved != null) {
      write("${node.identifier}Node");
    } else {
      String type = _types[node.identifier];
      write(type);
    }
    if (node.isList) write('>');
  }
}
