import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Only ever constructed with a [url] from GameEntry.embedUrl — i.e. only
/// for entries where embedding has been explicitly permitted. Anything
/// without that permission goes through the external-launch path instead
/// (see GamesScreen._openGame).
class GameWebViewScreen extends StatefulWidget {
  const GameWebViewScreen({super.key, required this.title, required this.url});
  final String title;
  final String url;

  @override
  State<GameWebViewScreen> createState() => _GameWebViewScreenState();
}

class _GameWebViewScreenState extends State<GameWebViewScreen> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (_) => setState(() => _loading = false),
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
