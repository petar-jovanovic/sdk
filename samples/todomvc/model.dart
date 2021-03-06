// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library todomvc.model;

// Very simple model for a collection of TODO items.

class Item {
  String title;
  bool _done = false;

  Item(this.title);

  bool get done => _done;
  void complete() { _done = true; }
  void uncomplete() { _done = false; }
}

class Model {
  List<Item> todos;

  Model() : todos = new List<Item>();

  void createItem(String title) {
    assert(title.isNotEmpty);
    Item item = new Item(title);
    todos.add(item);
  }

  void deleteItem(int id) {
    if (id < todos.length) {
      todos.removeAt(id);
    }
  }

  void completeItem(int id) {
    if (id < todos.length) {
      todos[id].complete();
    }
  }

  void uncompleteItem(int id) {
    if (id < todos.length) {
      todos[id].uncomplete();
    }
  }

  void clearItems() {
    todos.removeWhere((item) => item.done);
  }

}
