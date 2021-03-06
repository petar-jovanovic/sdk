// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

package dartino;

class ListBuilder extends Builder {
  public ListBuilder() { }

  public int length;

  Builder readListElement(Builder builder, int index, int size) {
    builder.segment = segment;
    builder.base = base + index * size;
    return builder;
  }
}
