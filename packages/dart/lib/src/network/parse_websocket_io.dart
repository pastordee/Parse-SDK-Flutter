/// If you change this file, you should apply the same changes to the 'parse_websocket_html.dart' file
library;

import 'dart:io' as io;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocket {
  WebSocket._(this._webSocket);

  static const int connecting = 0;
  static const int open = 1;
  static const int closing = 2;
  static const int closed = 3;

  final io.WebSocket _webSocket;

  static Future<WebSocket> connect(String liveQueryURL) async {
    return WebSocket._(await io.WebSocket.connect(liveQueryURL));
  }

  int get readyState => _webSocket.readyState;

  Future<void> close() {
    return _webSocket.close();
  }

  WebSocketChannel createWebSocketChannel() {
    return IOWebSocketChannel(_webSocket);
  }
}
