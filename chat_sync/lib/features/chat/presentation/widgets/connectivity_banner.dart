// Banner sutil que indica el estado de conectividad.
//
// · Online   → no muestra nada (estado normal)
// · Offline  → banner rojo: "Sin conexión — los mensajes se enviarán al reconectar"
// · Degraded → banner naranja: "Conexión inestable — reintentando..."
//
// Se anima suavemente al aparecer/desaparecer para no ser intrusivo.

import 'package:flutter/material.dart';
import '../../../../core/network/connectivity_monitor.dart';

class ConnectivityBanner extends StatelessWidget {
  const ConnectivityBanner({super.key, required this.monitor});

  final ConnectivityMonitor monitor;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<NetworkStatus>(
      stream: monitor.statusStream,
      initialData: monitor.currentStatus,
      builder: (context, snapshot) {
        final status = snapshot.data ?? NetworkStatus.online;

        // Sin banner cuando hay conexión normal
        if (status == NetworkStatus.online) {
          return const SizedBox.shrink();
        }

        final isOffline = status == NetworkStatus.offline;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          color: isOffline ? Colors.red.shade700 : Colors.orange.shade700,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
          child: Row(
            children: [
              Icon(isOffline ? Icons.wifi_off : Icons.wifi_find, color: Colors.white, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isOffline
                      ? 'Sin conexión — los mensajes se enviarán al reconectar'
                      : 'Conexión inestable — reintentando...',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
