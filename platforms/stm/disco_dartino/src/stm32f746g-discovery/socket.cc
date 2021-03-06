// Copyright (c) 2016, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "src/vm/hash_map.h"
#include "platforms/stm/disco_dartino/src/device_manager.h"

#include "platforms/stm/disco_dartino/src/stm32f746g-discovery/socket.h"

// TODO(karlklose): count number of sockets in the socket set and disable
// SocketHandlerTask when no sockets wait for events.

dartino::HashMap<Socket_t, uint32_t> sockets_ =
  dartino::HashMap<Socket_t, uint32_t>();

SocketSet_t socketSet_ = NULL;
TaskHandle_t socketHandlerTask_ = NULL;

dartino::DeviceManager* GetDeviceManager() {
  return dartino::DeviceManager::GetDeviceManager();
}

uint32_t RegisterSocket(Socket_t socket) {
  uint32_t handle = GetDeviceManager()->CreateSocket();
  sockets_[socket] = handle;
  return handle;
}

void ListenForSocketEvent(Socket_t socket, uint32_t mask) {
  if (socketHandlerTask_ == NULL) {
    socketSet_ = FreeRTOS_CreateSocketSet();
    xTaskCreate(SocketHandlerTask, "SOCKETS", 128, NULL, osPriorityHigh,
                &socketHandlerTask_);
  }
  FreeRTOS_FD_SET(socket, socketSet_, mask);
}

void UnregisterAndCloseSocket(Socket_t socket) {
  FreeRTOS_FD_CLR(socket, socketSet_, eSELECT_ALL);
  uint32_t handle = sockets_[socket];
  dartino::Device* device = GetDeviceManager()->GetDevice(handle);
  GetDeviceManager()->RemoveDevice(device);
  sockets_[socket] = 0;
  FreeRTOS_closesocket(socket);
}

uint32_t SocketConnect(Socket_t socket, uint32_t address, uint32_t port) {
  struct freertos_sockaddr sockaddr;
  sockaddr.sin_addr = address;
  sockaddr.sin_port = port;
  return FreeRTOS_connect(socket, &sockaddr, sizeof(sockaddr));
}

void ResetSocketFlags(uint32_t handle) {
  GetDeviceManager()->GetDevice(handle)->ClearFlags(eSELECT_ALL);
}

void SocketHandlerTask(void *parameters) {
  (void) parameters;
  for (;;) {
    if (FreeRTOS_select(socketSet_, pdMS_TO_TICKS(200)) != 0) {
      for (auto it = sockets_.begin(); it != sockets_.end(); ++it) {
        Socket_t socket = it->first;
        uint32_t handle = it->second;
        BaseType_t events = FreeRTOS_FD_ISSET(socket, socketSet_);
        if (events != 0) {
          GetDeviceManager()->GetDevice(handle)->SetFlags(events);
          FreeRTOS_FD_CLR(socket, socketSet_, events);
        }
      }
    }
  }
}
