import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';

/* =========================
   THEME
========================= */

final ThemeData appTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xFF121212),
  colorScheme: const ColorScheme.dark(
    primary: Colors.green,
    secondary: Colors.orange,
    error: Colors.red,
  ),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(color: Colors.white),
  ),
);

/* =========================
   MAIN
========================= */

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme,
      home: const AppRoot(),
    );
  }
}

/* =========================
   ROOT
========================= */

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  // [FIX] Singleton engine — evita recriação em rebuilds
  final CartEngine engine = CartEngine();
  bool ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    engine.setBudget(prefs.getDouble('budget') ?? 0);

    // [FIX] Aguarda DB inicializar antes de carregar dados
    await engine.loadPersisted();

    if (!mounted) return; // [FIX] Guard para contexto desmontado

    if (engine.budget == 0) {
      final value = await _budgetDialog();
      if (value != null) {
        engine.setBudget(value);
        await prefs.setDouble('budget', value); // [FIX] await na gravação
      }
    }

    if (mounted) setState(() => ready = true);
  }

  Future<double?> _budgetDialog() async {
    final c = TextEditingController();
    return showDialog<double>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Orçamento'),
        content: TextField(
          controller: c,
          autofocus: true, // [UX] Teclado abre automaticamente
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          // [UX] Submete com "Done" no teclado
          onSubmitted: (_) {
            final v = double.tryParse(c.text.replaceAll(',', '.'));
            if (v != null && v > 0) Navigator.pop(context, v);
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              final v = double.tryParse(c.text.replaceAll(',', '.'));
              if (v != null && v > 0) Navigator.pop(context, v);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // [PERF] Tela preta simples — sem widget pesado no loading
    if (!ready) return const Scaffold(backgroundColor: Colors.black);
    return CleanUI(engine: engine);
  }
}

/* =========================
   ENGINE
========================= */

class CartItem {
  String code;
  String name;
  double price;
  int timestamp;

  CartItem({
    required this.code,
    required this.name,
    required this.price,
    required this.timestamp,
  });
}

class CartEngine {
  List<CartItem> items = [];
  double budget = 0;

  void setBudget(double v) => budget = v;

  void add(CartItem i) {
    items.add(i);
    persist();
  }

  void remove(int i) {
    if (i < 0 || i >= items.length) return; // [FIX] Guard contra index inválido
    items.removeAt(i);
    persist();
  }

  void update(int i, double p) {
    if (i < 0 || i >= items.length) return; // [FIX] Guard contra index inválido
    items[i].price = p;
    persist();
  }

  Map<String, dynamic> calc() {
    final double total = items.fold(0.0, (a, b) => a + b.price);
    final double remaining = budget - total;

    String status = 'ok';
    if (budget > 0) {
      final double r = total / budget;
      if (r >= 1.0) {
        status = 'limit';
      } else if (r >= 0.8) {
        status = 'warn';
      }
    }

    return {
      'total': total,
      'remaining': remaining,
      'status': status,
    };
  }

  // [FIX] Debounce na persistência — evita writes excessivos ao DB
  Timer? _persistTimer;

  void persist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 300), _writeToDB);
  }

  Future<void> _writeToDB() async {
    try {
      final db = await DB.instance.db;
      await db.transaction((txn) async {
        // [FIX] Transaction atômica — sem risco de estado parcial
        await txn.delete('cart');
        for (final i in items) {
          await txn.insert('cart', {
            'code': i.code,
            'name': i.name,
            'price': i.price,
            'ts': i.timestamp,
          });
        }
      });
    } catch (e) {
      // [FIX] Silencia crash de DB — não derruba o app
      debugPrint('DB persist error: $e');
    }
  }

  Future<void> loadPersisted() async {
    try {
      final db = await DB.instance.db;
      final res = await db.query('cart', orderBy: 'ts ASC'); // [FIX] Ordem consistente

      items = res
          .map((e) => CartItem(
                code: e['code'] as String,
                name: e['name'] as String? ?? '',
                price: (e['price'] as num).toDouble(),
                timestamp: e['ts'] as int,
              ))
          .toList();
    } catch (e) {
      debugPrint('DB load error: $e');
      items = []; // [FIX] Fallback seguro em vez de crash
    }
  }
}

/* =========================
   DB
========================= */

class DB {
  // [FIX] Singleton correto com named constructor privado
  static final DB instance = DB._();
  DB._();

  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), 'app.db');

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute(
          'CREATE TABLE cart(code TEXT, name TEXT, price REAL, ts INTEGER)',
        );
      },
    );

    return _db!;
  }
}

/* =========================
   UI
========================= */

class CleanUI extends StatefulWidget {
  final CartEngine engine;
  const CleanUI({super.key, required this.engine});

  @override
  State<CleanUI> createState() => _CleanUIState();
}

class _CleanUIState extends State<CleanUI> {
  String _lastStatus = '';

  // [FIX] Controle de scan duplicado — ignora scans dentro de 1.5s do mesmo código
  String? _lastScannedCode;
  DateTime? _lastScanTime;
  static const _scanCooldown = Duration(milliseconds: 1500);

  // [FIX] Flag async — impede múltiplos dialogs simultâneos
  bool _dialogOpen = false;

  // [FIX] Controller do scanner para controle de lifecycle
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates, // [PERF] Reduz processamento
    returnImage: false, // [PERF] Não retorna imagem — menor uso de memória
  );

  @override
  void dispose() {
    _scannerController.dispose(); // [FIX] Libera câmera corretamente
    super.dispose();
  }

  bool _isDuplicateScan(String code) {
    final now = DateTime.now();
    if (_lastScannedCode == code &&
        _lastScanTime != null &&
        now.difference(_lastScanTime!) < _scanCooldown) {
      return true;
    }
    _lastScannedCode = code;
    _lastScanTime = now;
    return false;
  }

  void onScan(String code) async {
    // [FIX] Dupla proteção: cooldown + flag de dialog
    if (_isDuplicateScan(code)) return;
    if (_dialogOpen) return;

    _dialogOpen = true;
    final price = await _priceDialog();
    _dialogOpen = false;

    if (price == null) return;
    if (!mounted) return; // [FIX] Guard pós-await

    widget.engine.add(
      CartItem(
        code: code,
        name: '',
        price: price,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    final s = widget.engine.calc();
    _feedback(s['status'] as String);
    setState(() {});
  }

  void _feedback(String status) {
    if (status == _lastStatus) return;

    // [PERF] HapticFeedback só quando status muda
    if (status == 'warn') HapticFeedback.mediumImpact();
    if (status == 'limit') HapticFeedback.heavyImpact();

    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars() // [FIX] Remove snackbars anteriores acumulados
        ..showSnackBar(
          SnackBar(
            content: Text(status == 'warn'
                ? '⚠️ Atenção: 80% do orçamento'
                : status == 'limit'
                    ? '🔴 Limite atingido!'
                    : status),
            duration: const Duration(milliseconds: 1200),
          ),
        );
    }

    _lastStatus = status;
  }

  Future<double?> _priceDialog() async {
    final c = TextEditingController();

    return showDialog<double>(
      context: context,
      barrierDismissible: false, // [UX] Não fecha ao clicar fora acidentalmente
      builder: (_) => AlertDialog(
        title: const Text('Preço'),
        content: TextField(
          controller: c,
          autofocus: true, // [UX] Teclado abre imediatamente
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onSubmitted: (_) {
            final v = double.tryParse(c.text.replaceAll(',', '.'));
            if (v != null && v >= 0) Navigator.pop(context, v);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null), // [UX] Cancela explicitamente
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              final v = double.tryParse(c.text.replaceAll(',', '.'));
              if (v != null && v >= 0) Navigator.pop(context, v);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Color _statusColor(String s) {
    if (s == 'warn') return Colors.orange;
    if (s == 'limit') return Colors.red;
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.engine.calc();
    final double total = s['total'] as double;
    final double remaining = s['remaining'] as double;
    final String status = s['status'] as String;
    final color = _statusColor(status);

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Stack(
        children: [
          // [PERF] Controller explícito — lifecycle controlado
          MobileScanner(
            controller: _scannerController,
            onDetect: (cap) {
              final raw = cap.barcodes.firstOrNull?.rawValue;
              if (raw != null && raw.isNotEmpty) onScan(raw);
            },
          ),

          // Overlay de totais
          Positioned(
            top: 60,
            left: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'R\$ ${remaining.toStringAsFixed(2)}',
                  style: TextStyle(
                    color: color,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Total: R\$ ${total.toStringAsFixed(2)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                // [UX] Mostra quantidade de itens
                Text(
                  '${widget.engine.items.length} item(s)',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),

          // Painel deslizante de itens
          DraggableScrollableSheet(
            initialChildSize: 0.08,
            minChildSize: 0.08,
            maxChildSize: 0.4,
            builder: (_, ctrl) => Container(
              decoration: const BoxDecoration(
                color: Color(0xFF1E1E1E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Column(
                children: [
                  // Handle visual
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white38,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const Text(
                    'Arraste para ver itens',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  Expanded(
                    child: widget.engine.items.isEmpty
                        ? const Center(
                            child: Text(
                              'Nenhum item escaneado',
                              style: TextStyle(color: Colors.white24),
                            ),
                          )
                        : ListView.builder(
                            controller: ctrl,
                            itemCount: widget.engine.items.length,
                            itemBuilder: (_, i) {
                              // [FIX] Guard — lista pode mudar durante build
                              if (i >= widget.engine.items.length) {
                                return const SizedBox.shrink();
                              }
                              final it = widget.engine.items[i];

                              return ListTile(
                                dense: true,
                                title: Text(
                                  'R\$ ${it.price.toStringAsFixed(2)}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                                subtitle: it.code.isNotEmpty
                                    ? Text(
                                        it.code,
                                        style: const TextStyle(
                                            color: Colors.white38,
                                            fontSize: 11),
                                        overflow: TextOverflow.ellipsis,
                                      )
                                    : null,
                                trailing: IconButton(
                                  // [UX] Botão de remoção explícito além do long press
                                  icon: const Icon(Icons.close,
                                      color: Colors.white38, size: 18),
                                  onPressed: () {
                                    widget.engine.remove(i);
                                    setState(() {});
                                  },
                                ),
                                onTap: () async {
                                  final p = await _priceDialog();
                                  if (p != null && mounted) {
                                    widget.engine.update(i, p);
                                    setState(() {});
                                  }
                                },
                                onLongPress: () {
                                  widget.engine.remove(i);
                                  setState(() {});
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
