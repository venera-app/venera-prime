import 'package:integration_test/integration_test.dart';
import '../test/support/reader_spread_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerReaderSpreadTests(device: true);
}
