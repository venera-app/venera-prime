import 'package:integration_test/integration_test.dart';
import '../test/support/data_sync_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerDataSyncTransportTests(device: true);
}
