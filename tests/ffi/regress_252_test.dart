// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

// Looking up a library should not make the symbols reachable from main lookup
// unless we explicitly pass the global flag.

import 'dart:dartino.ffi';
import "package:expect/expect.dart";

bool isArgumentError(e) => e is ArgumentError;

void main() {
  var libPath = ForeignLibrary.bundleLibraryName('ffi_test_local_library');
  ForeignLibrary fl = new ForeignLibrary.fromName(libPath);
  Expect.throws(
      () => ForeignLibrary.main.lookup('memuint32'),
      isArgumentError);

  libPath = ForeignLibrary.bundleLibraryName('ffi_test_library');
  ForeignLibrary flGlobal = new ForeignLibrary.fromName(libPath, global: true);
  var memuint32 = ForeignLibrary.main.lookup('memuint32');
  var memory =
      new ForeignMemory.fromAddressFinalized(memuint32.pcall$0().address, 16);
  Expect.equals(memory.getUint32(0), 0);
  Expect.equals(memory.getUint32(4), 1);
  Expect.equals(memory.getUint32(8), 65536);
  Expect.equals(memory.getUint32(12), 4294967295);
}
