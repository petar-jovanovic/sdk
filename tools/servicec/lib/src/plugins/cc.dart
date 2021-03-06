// Copyright (c) 2015, the Dartino project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library old_servicec.plugins.cc;

import 'dart:core' hide Type;
import 'dart:io' show Platform, File;

import 'package:path/path.dart' show basenameWithoutExtension, join, dirname;
import 'package:servicec/util.dart' as strings;

import 'shared.dart';

import '../emitter.dart';
import '../primitives.dart' as primitives;
import '../struct_layout.dart';

const COPYRIGHT = """
// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.
""";

const List<String> RESOURCES = const [
  "struct.h",
  "struct.cc",
  "unicode.h",
  "unicode.cc",
];

const int RESPONSE_HEADER_SIZE = 8;

void generate(String path,
              Unit unit,
              String resourcesDirectory,
              String outputDirectory) {
  String directory = join(outputDirectory, "cc");
  _generateHeaderFile(path, unit, directory);
  _generateImplementationFile(path, unit, directory);

  resourcesDirectory = join(resourcesDirectory, 'cc');
  for (String resource in RESOURCES) {
    String resourcePath = join(resourcesDirectory, resource);
    File file = new File(resourcePath);
    String contents = file.readAsStringSync();
    writeToFile(directory, resource, contents);
  }
}

void _generateHeaderFile(String path, Unit unit, String directory) {
  _HeaderVisitor visitor = new _HeaderVisitor(path);
  visitor.visit(unit);
  String contents = visitor.buffer.toString();
  writeToFile(directory, path, contents, extension: 'h');
}

void _generateImplementationFile(String path, Unit unit, String directory) {
  _ImplementationVisitor visitor = new _ImplementationVisitor(path);
  visitor.visit(unit);
  String contents = visitor.buffer.toString();
  writeToFile(directory, path, contents, extension: 'cc');
}

abstract class CcVisitor extends CodeGenerationVisitor {
  CcVisitor(String path) : super(path);

  static const int REQUEST_HEADER_SIZE = 56;
  static const PRIMITIVE_TYPES = const <String, String> {
    'void'    : 'void',
    'bool'    : 'bool',

    'uint8'   : 'uint8_t',
    'uint16'  : 'uint16_t',

    'int8'    : 'int8_t',
    'int16'   : 'int16_t',
    'int32'   : 'int32_t',
    'int64'   : 'int64_t',

    'float32' : 'float',
    'float64' : 'double',
  };

  static String cast(String type, bool cStyle) => cStyle
      ? '($type)'
      : 'reinterpret_cast<$type>';

  visitUnion(Union node) {
    throw "Unreachable";
  }

  visitFormal(Formal node) {
    writeType(node.type);
    write(' ${node.name}');
  }

  void writeType(Type node) {
    Node resolved = node.resolved;
    if (resolved != null) {
      write('${node.identifier}Builder');
    } else {
      String type = PRIMITIVE_TYPES[node.identifier];
      write(type);
    }
  }

  void writeReturnType(Type node) {
    Node resolved = node.resolved;
    if (resolved != null) {
      write('${node.identifier}');
    } else {
      String type = PRIMITIVE_TYPES[node.identifier];
      write(type);
    }
  }

  visitArguments(List<Formal> formals) {
    visitNodes(formals, (first) => first ? '' : ', ');
  }

  visitStructArgumentMethodBody(String id,
                                Method method,
                                {String callback}) {
    bool async = callback != null;
    String argumentName = method.arguments.single.name;
    if (method.outputKind == OutputKind.STRUCT) {
      if (async) {
        write('  ');
        writeln('$argumentName.InvokeMethodAsync(service_id_, $id,'
                ' $callback, reinterpret_cast<void*>(callback), callback_data);');
      } else {
        writeln('  int64_t result = $argumentName.'
                'InvokeMethod(service_id_, $id);');
        writeln('  char* memory = reinterpret_cast<char*>(result);');
        // TODO(ajohnsen): Do range-check between size and segment size.
        writeln('  Segment* segment = MessageReader::GetRootSegment(memory);');
        writeln('  return ${method.returnType.identifier}'
                '(segment, $RESPONSE_HEADER_SIZE);');
      }
    } else {
      write('  ');
      if (!method.returnType.isVoid && !async) write('return ');
      String suffix = async ? 'Async' : '';
      String cb = async ? ', $callback, reinterpret_cast<void*>(callback), callback_data' : '';
      writeln('$argumentName.InvokeMethod$suffix(service_id_, $id$cb);');
    }
  }

  visitMethodBody(String id,
                  Method method,
                  {bool cStyle: false,
                   List<String> extraArguments: const [],
                   String callback}) {
    List<Formal> arguments = method.arguments;
    assert(method.inputKind == InputKind.PRIMITIVES);
    StructLayout layout = method.inputPrimitiveStructLayout;
    final bool async = callback != null;
    int size = REQUEST_HEADER_SIZE + layout.size;
    if (async) {
      write('  static const int kSize = ');
      writeln('${size} + ${extraArguments.length} * sizeof(void*);');
    } else {
      writeln('  static const int kSize = ${size};');
    }

    String cast(String type) => CcVisitor.cast(type, cStyle);

    String pointerToArgument(int offset, int pointers, String type) {
      offset += REQUEST_HEADER_SIZE;
      String prefix = cast('$type*');
      if (pointers == 0) return '$prefix(_buffer + $offset)';
      return '$prefix(_buffer + $offset + $pointers * sizeof(void*))';
    }

    if (async) {
      writeln('  char* _buffer = ${cast("char*")}(malloc(kSize));');
    } else {
      writeln('  char _bits[kSize];');
      writeln('  char* _buffer = _bits;');
    }

    // Mark the message as being non-segmented.
    writeln('  *${pointerToArgument(-8, 0, "int64_t")} = 0;');

    int arity = arguments.length;
    for (int i = 0; i < arity; i++) {
      String name = arguments[i].name;
      int offset = layout[arguments[i]].offset;
      String type = PRIMITIVE_TYPES[arguments[i].type.identifier];
      writeln('  *${pointerToArgument(offset, 0, type)} = $name;');
    }

    if (async) {
      String callbackFunction = pointerToArgument(-16, 0, 'void*');
      String callbackData = pointerToArgument(-24, 0, 'void*');
      writeln('  *$callbackFunction = ${cast("void*")}(callback);');
      writeln('  *$callbackData = callback_data;');
      for (int i = 0; i < extraArguments.length; i++) {
        String dataArgument = pointerToArgument(layout.size, i, 'void*');
        String arg = extraArguments[i];
        writeln('  *$dataArgument = ${cast("void*")}($arg);');
      }
      write('  ServiceApiInvokeAsync(service_id_, $id, $callback, ');
      writeln('_buffer, kSize);');
    } else {
      writeln('  ServiceApiInvoke(service_id_, $id, _buffer, kSize);');
      if (method.outputKind == OutputKind.STRUCT) {
        writeln('  int64_t result = *${pointerToArgument(0, 0, 'int64_t')};');
        writeln('  char* memory = reinterpret_cast<char*>(result);');
        // TODO(ajohnsen): Do range-check between size and segment size.
        writeln('  Segment* segment = MessageReader::GetRootSegment(memory);');
        writeln('  return ${method.returnType.identifier}'
                '(segment, $RESPONSE_HEADER_SIZE);');
      } else if (!method.returnType.isVoid) {
        writeln('  return *${pointerToArgument(0, 0, 'int64_t')};');
      }
    }
  }
}

class _HeaderVisitor extends CcVisitor {
  _HeaderVisitor(String path) : super(path);

  String computeHeaderGuard() {
    String base = basenameWithoutExtension(path).toUpperCase();
    return '${base}_H';
  }

  visitUnit(Unit node) {
    String headerGuard = computeHeaderGuard();
    writeln(COPYRIGHT);

    writeln('// Generated file. Do not edit.');
    writeln();

    writeln('#ifndef $headerGuard');
    writeln('#define $headerGuard');

    writeln();
    writeln('#include <inttypes.h>');
    writeln('#include "struct.h"');

    if (node.structs.isNotEmpty) writeln();
    for (Struct struct in node.structs) {
      writeln('class ${struct.name};');
      writeln('class ${struct.name}Builder;');
    }

    node.services.forEach(visit);
    node.structs.forEach(visit);

    writeln();
    writeln('#endif  // $headerGuard');
  }

  visitService(Service node) {
    writeln();
    writeln('class ${node.name} {');
    writeln(' public:');
    writeln('  static void setup();');
    writeln('  static void tearDown();');

    node.methods.forEach(visit);

    writeln('};');
  }

  visitMethod(Method node) {
    write('  static ');
    writeReturnType(node.returnType);
    write(' ${node.name}(');
    visitArguments(node.arguments);
    writeln(');');

    write('  static void ${node.name}Async(');
    visitArguments(node.arguments);
    if (node.arguments.isNotEmpty) write(', ');
    write('void (*callback)(');
    if (!node.returnType.isVoid) {
      writeReturnType(node.returnType);
      write(', ');
    }
    writeln('void*), void* callback_data);');
  }

  visitStruct(Struct node) {
    writeReader(node);
    writeBuilder(node);
  }

  void writeReader(Struct node) {
    String name = node.name;
    StructLayout layout = node.layout;

    writeln();
    writeln('class $name : public Reader {');
    writeln(' public:');
    writeln('  static const int kSize = ${layout.size};');

    writeln('  $name(Segment* segment, int offset)');
    writeln('      : Reader(segment, offset) { }');
    writeln();

    for (StructSlot slot in layout.slots) {
      Type slotType = slot.slot.type;
      String camel = camelize(slot.slot.name);

      if (slot.isUnionSlot) {
        String tagName = camelize(slot.union.tag.name);
        int tag = slot.unionTag;
        writeln('  bool is$camel() const { return $tag == get$tagName(); }');
      }

      if (slotType.isList) {
        write('  ');
        write('List<');
        writeReturnType(slotType);
        write('> get$camel() const { ');
        write('return ReadList<');
        writeReturnType(slotType);
        writeln('>(${slot.offset}); }');
      } else if (slotType.isVoid) {
        // No getters for void slots.
      } else if (slotType.isString) {
        writeln('  char* get$camel() const '
                '{ return ReadString(${slot.offset}); }');
        writeln('  List<uint16_t> get${camel}Data() const '
                '{ return ReadList<uint16_t>(${slot.offset}); }');
      } else if (slotType.isPrimitive) {
        write('  ');
        writeType(slotType);
        write(' get$camel() const { return *PointerTo<');
        if (slotType.isBool) {
          writeln('uint8_t>(${slot.offset}) != 0; }');
        } else {
          writeType(slotType);
          writeln('>(${slot.offset}); }');
        }
      } else {
        write('  ');
        writeReturnType(slotType);
        writeln(' get$camel() const;');
      }
    }

    writeln('};');
  }

  void writeBuilder(Struct node) {
    String name = "${node.name}Builder";
    StructLayout layout = node.layout;

    writeln();
    writeln('class $name : public Builder {');
    writeln(' public:');
    writeln('  static const int kSize = ${layout.size};');
    writeln();

    writeln('  explicit $name(const Builder& builder)');
    writeln('      : Builder(builder) { }');
    writeln('  $name(Segment* segment, int offset)');
    writeln('      : Builder(segment, offset) { }');
    writeln();

    for (StructSlot slot in layout.slots) {
      String slotName = slot.slot.name;
      Type slotType = slot.slot.type;

      String updateTag = '';
      if (slot.isUnionSlot) {
        String tagName = camelize(slot.union.tag.name);
        int tag = slot.unionTag;
        updateTag = 'set$tagName($tag); ';
      }

      String camel = camelize(slotName);
      if (slotType.isList) {
        write('  List<');
        writeType(slotType);
        writeln('> init$camel(int length);');
      } else if (slotType.isVoid) {
        assert(slot.isUnionSlot);
        String tagName = camelize(slot.union.tag.name);
        int tag = slot.unionTag;
        writeln('  void set$camel() { set$tagName($tag); }');
      } else if (slotType.isString) {
        write('  void set$camel(const char* value) { ');
        write(updateTag);
        writeln('NewString(${slot.offset}, value); }');
        writeln('  List<uint16_t> init${camel}Data(int length);');
      } else if (slotType.isPrimitive) {
        write('  void set$camel(');
        writeType(slotType);
        write(' value) { ');
        write(updateTag);
        write('*PointerTo<');
        if (slotType.isBool) {
          writeln('uint8_t>(${slot.offset}) = value ? 1 : 0; }');
        } else {
          writeType(slotType);
          writeln('>(${slot.offset}) = value; }');
        }
      } else {
        write('  ');
        writeType(slotType);
        writeln(' init$camel();');
      }
    }

    writeln('};');
  }
}

class _ImplementationVisitor extends CcVisitor {
  int methodId = 1;
  String serviceName;

  _ImplementationVisitor(String path) : super(path);

  String computeHeaderFile() {
    String base = basenameWithoutExtension(path);
    return '$base.h';
  }

  visitUnit(Unit node) {
    String headerFile = computeHeaderFile();
    writeln(COPYRIGHT);

    writeln('// Generated file. Do not edit.');
    writeln();

    writeln('#include "$headerFile"');
    writeln('#include "include/service_api.h"');
    writeln('#include <stdlib.h>');

    node.services.forEach(visit);
    node.structs.forEach(visit);
  }

  visitService(Service node) {
    writeln();
    writeln('static ServiceId service_id_ = kNoServiceId;');

    serviceName = node.name;

    writeln();
    writeln('void ${serviceName}::setup() {');
    writeln('  service_id_ = ServiceApiLookup("$serviceName");');
    writeln('}');

    writeln();
    writeln('void ${serviceName}::tearDown() {');
    writeln('  ServiceApiTerminate(service_id_);');
    writeln('  service_id_ = kNoServiceId;');
    writeln('}');

    node.methods.forEach(visit);
  }

  visitStruct(Struct node) {
    writeBuilder(node);
    writeReader(node);
  }

  void writeBuilder(Struct node) {
    String name = "${node.name}Builder";
    StructLayout layout = node.layout;

    for (StructSlot slot in layout.slots) {
      String slotName = slot.slot.name;
      Type slotType = slot.slot.type;

      String updateTag = '';
      if (slot.isUnionSlot) {
        String tagName = camelize(slot.union.tag.name);
        int tag = slot.unionTag;
        updateTag = '  set$tagName($tag);\n';
      }

      String camel = camelize(slotName);
      if (slotType.isList) {
        writeln();
        write('List<');
        writeType(slotType);
        writeln('> $name::init$camel(int length) {');
        write(updateTag);
        int size = 0;
        if (slotType.isPrimitive) {
          size = primitives.size(slotType.primitiveType);
        } else {
          Struct element = slot.slot.type.resolved;
          StructLayout elementLayout = element.layout;
          size = elementLayout.size;
        }
        writeln('  Reader result = NewList(${slot.offset}, length, $size);');
        write('  return List<');
        writeType(slotType);
        writeln('>(result.segment(), result.offset(), length);');
        writeln('}');
      } else if (slotType.isString) {
        writeln();
        writeln('List<uint16_t> $name::init${camel}Data(int length) {');
        write(updateTag);
        writeln('  Reader result = NewList(${slot.offset}, length, 2);');
        writeln('  return List<uint16_t>(result.segment(), result.offset(),'
                ' length);');
        writeln('}');
      } else if (!slotType.isPrimitive) {
        writeln();
        writeType(slotType);
        writeln(' $name::init$camel() {');
        Struct element = slot.slot.type.resolved;
        StructLayout elementLayout = element.layout;
        int size = elementLayout.size;
        write(updateTag);
        if (!slotType.isPointer) {
          write('  return ');
          writeType(slotType);
          writeln('(segment(), offset() + ${slot.offset});');
        } else {
          writeln('  Builder result = NewStruct(${slot.offset}, $size);');
          write('  return ');
          writeType(slotType);
          writeln('(result);');
        }
        writeln('}');
      }
    }
  }

  void writeReader(Struct node) {
    String name = "${node.name}";
    StructLayout layout = node.layout;

    for (StructSlot slot in layout.slots) {
      String slotName = slot.slot.name;
      Type slotType = slot.slot.type;

      String camel = camelize(slotName);
      if (!slotType.isPrimitive && !slotType.isList && !slotType.isString) {
        writeln();
        writeReturnType(slotType);
        write(' $name::get$camel() const { return ');
        if (!slotType.isPointer) {
          writeReturnType(slotType);
          writeln('(segment(), offset() + ${slot.offset}); }');
        } else {
          write('ReadStruct<');
          writeReturnType(slotType);
          writeln('>(${slot.offset}); }');
        }
      }
    }
  }

  visitMethod(Method node) {
    String name = node.name;
    String id = 'k${camelize(name)}Id_';

    writeln();
    write('static const MethodId $id = ');
    writeln('reinterpret_cast<MethodId>(${methodId++});');

    writeln();
    writeReturnType(node.returnType);
    write(' $serviceName::${name}(');
    visitArguments(node.arguments);
    writeln(') {');

    if (node.inputKind == InputKind.STRUCT) {
      visitStructArgumentMethodBody(id, node);
    } else {
      assert(node.inputKind == InputKind.PRIMITIVES);
      visitMethodBody(id, node);
    }

    writeln('}');

    String callback;
    if (node.inputKind == InputKind.STRUCT) {
      Struct struct = node.arguments.single.type.resolved;
      StructLayout layout = struct.layout;
      callback = ensureCallback(node.returnType, layout);
    } else {
      callback =
          ensureCallback(node.returnType, node.inputPrimitiveStructLayout);
    }

    writeln();
    write('void $serviceName::${name}Async(');
    visitArguments(node.arguments);
    if (node.arguments.isNotEmpty) write(', ');
    write('void (*callback)(');
    if (!node.returnType.isVoid) {
      writeReturnType(node.returnType);
      write(', ');
    }
    writeln('void*), void* callback_data) {');

    if (node.inputKind == InputKind.STRUCT) {
      visitStructArgumentMethodBody(id, node, callback: callback);
    } else {
      visitMethodBody(id, node, callback: callback);
    }

    writeln('}');
  }

  final Map<String, String> callbacks = {};
  String ensureCallback(Type type,
                        StructLayout layout,
                        {bool cStyle: false}) {
    String key = '${type.identifier}_${layout.size}';
    return callbacks.putIfAbsent(key, () {
      String cast(String type) => CcVisitor.cast(type, cStyle);
      String pointerToArgument(int offset, int pointers, String type) {
        offset += CcVisitor.REQUEST_HEADER_SIZE;
        String prefix = cast('$type*');
        if (pointers == 0) return '$prefix(buffer + $offset)';
        return '$prefix(buffer + $offset + $pointers * sizeof(void*))';
      }
      String name = 'Unwrap_$key';
      writeln();
      writeln('static void $name(void* raw) {');
      if (type.isVoid) {
        writeln('  typedef void (*cbt)(void*);');
      } else {
        write('  typedef void (*cbt)(');
        writeReturnType(type);
        writeln(', void*);');
      }
      writeln('  char* buffer = ${cast('char*')}(raw);');
      int offset = CcVisitor.REQUEST_HEADER_SIZE;
      if (!type.isVoid) {
        writeln('  int64_t result = *${cast('int64_t*')}(buffer + $offset);');
        if (!type.isPrimitive) {
          writeln('  char* memory = reinterpret_cast<char*>(result);');
          writeln('  Segment* segment = '
                  'MessageReader::GetRootSegment(memory);');
        }
      }
      String callbackFunction = pointerToArgument(-16, 0, 'cbt');
      String callbackData = pointerToArgument(-24, 0, 'void*');
      writeln('  cbt callback = *$callbackFunction;');
      writeln('  void* callback_data = *$callbackData;');
      writeln('  MessageBuilder::DeleteMessage(buffer);');
      if (type.isVoid) {
        writeln('  callback(callback_data);');
      } else {
        if (type.isPrimitive) {
          writeln('  callback(result, callback_data);');
        } else {
          write('  callback(');
          writeReturnType(type);
          writeln('(segment, 8), callback_data);');
        }
      }
      writeln('}');
      return name;
    });
  }
}
