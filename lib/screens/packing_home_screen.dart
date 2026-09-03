import 'package:flutter/material.dart';

import '../app/app_build_config.dart';
import '../controllers/packing_session_controller.dart';
import '../services/session_repository.dart';

class PackingHomeScreen extends StatefulWidget {
  const PackingHomeScreen({
    required this.repository,
    required this.buildConfig,
    super.key,
  });

  final SessionRepository repository;
  final AppBuildConfig buildConfig;

  @override
  State<PackingHomeScreen> createState() => _PackingHomeScreenState();
}

class _PackingHomeScreenState extends State<PackingHomeScreen> {
  late final PackingSessionController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PackingSessionController(repository: widget.repository);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.buildConfig.appTitle),
      ),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(Icons.camera_alt_outlined, size: 64),
                const SizedBox(height: 16),
                Text(
                  '包裹留证准备就绪',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
