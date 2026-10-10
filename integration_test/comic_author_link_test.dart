import 'package:integration_test/integration_test.dart';
import '../test/support/comic_author_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerComicAuthorTests(device: true);
}
