APP_NAME := CodexPromptAssistantPOC
APP_BUNDLE := build/$(APP_NAME).app
APP_EXECUTABLE := $(APP_BUNDLE)/Contents/MacOS/CodexPromptAssistantPOC
APP_IDENTIFIER := local.codex.prompt-assistant-poc
INSTALLED_APP_BUNDLE := $(HOME)/Applications/$(APP_NAME).app
APP_SERVICE_LABEL := local.codex.prompt-assistant-app
APP_SERVICE_PLIST := $(HOME)/Library/LaunchAgents/$(APP_SERVICE_LABEL).plist
SOURCES := $(wildcard Sources/CodexPromptAssistantPOC/*.m)
BUILD_METADATA_DIR := .build/generated
BUILD_METADATA_HEADER := $(BUILD_METADATA_DIR)/CPABuildMetadata.h
APP_HEADERS := $(wildcard Sources/*/*.h)
COMMON_FLAGS := -I$(BUILD_METADATA_DIR) -fobjc-arc -fmodules -Wall -Wextra -Werror
APP_FRAMEWORKS := -framework AppKit -framework ApplicationServices -framework Carbon -framework QuartzCore -framework Security -framework LocalAuthentication -lsqlite3
DATA_CORE_SOURCES := $(wildcard Sources/CodexDataCore/*.m)
APP_SOURCES := $(SOURCES) $(DATA_CORE_SOURCES) \
	$(wildcard Sources/ExpressionLibraryCore/*.m)
DATA_CORE_FRAMEWORKS := -framework Foundation -framework Security -framework LocalAuthentication -lsqlite3
CHATGPT_IMPORT_SOURCES := $(wildcard Sources/ChatGPTImportCore/*.m)
EXPRESSION_LIBRARY_SOURCES := $(wildcard Sources/ExpressionLibraryCore/*.m)
REMOTE_COMPLETION_SOURCES := $(wildcard Sources/RemoteCompletionCore/*.m)
APP_SOURCES += $(REMOTE_COMPLETION_SOURCES)

.PHONY: all app test application-recovery-test data-core-test expression-library-test remote-completion-test checkpoint-c-test phase2-checkpoint-test history-probe crypto-probe data-rebuild master-key-file-test local-model-benchmark prompt-assistant-service-install prompt-assistant-service-start prompt-assistant-service-stop prompt-assistant-service-status local-model-service-install local-model-service-start local-model-service-stop clean

all: app

# Test-only linkage and diagnostics. Public targets allocate/clean the run root.
TEST_FLAGS = $(if $(CPA_TEST_ROOT),$(COMMON_FLAGS) -DCPA_TEST_DIAGNOSTIC_LOG_PATH='"$(CPA_TEST_ROOT)/diagnostic.log"',$(error Use the public test target to allocate isolated resources))
TEST_DATA_CORE_SOURCES = $(filter-out Sources/CodexDataCore/KeychainStore.m,$(DATA_CORE_SOURCES)) Tests/Support/FixtureKeychainStore.m
TEST_APP_SOURCES = $(filter-out Sources/CodexDataCore/KeychainStore.m,$(APP_SOURCES)) Tests/Support/FixtureKeychainStore.m
ISOLATED_TEST_TARGETS := health-probe-test model-agent-test settings-window-test completion-quality-harness-test candidate-lifecycle-test local-model-service-test release-transaction-test release-preparation-test build-metadata-test wps-bridge-test test application-recovery-test application-policy-menu-test data-core-test master-key-file-test expression-library-test remote-completion-test checkpoint-c-test phase2-checkpoint-test
.PHONY: $(ISOLATED_TEST_TARGETS) $(addsuffix -run,$(ISOLATED_TEST_TARGETS)) test-data-rebuild test-isolation-test
$(ISOLATED_TEST_TARGETS):
	python3 Tools/Testing/run_isolated.py $(MAKE) $@-run

test-isolation-test:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/TestIsolationTests -v

test-data-rebuild:
	mkdir -p .build/tests
	clang $(TEST_FLAGS) $(DATA_CORE_FRAMEWORKS) $(TEST_DATA_CORE_SOURCES) \
		Tools/CodexDataRebuild/main.m -o .build/tests/CodexDataRebuild

# Metadata is regenerated on every invocation, but unchanged files keep their
# mtime. A new HEAD/dirty state must rebuild even when no .m file changed.
.PHONY: FORCE build-metadata-test build-info installed-build-info
FORCE:

$(BUILD_METADATA_HEADER): FORCE
	python3 Tools/BuildMetadata/build_metadata.py --output "$(BUILD_METADATA_DIR)"

app: $(APP_EXECUTABLE)
	cp "$(BUILD_METADATA_DIR)/Info.plist" "$(APP_BUNDLE)/Contents/Info.plist"
	cp Resources/AppIcon.icns Resources/StatusIcon.png Resources/StatusIcon@2x.png "$(APP_BUNDLE)/Contents/Resources/"
	cp -R Resources/zh_CN.lproj Resources/en.lproj "$(APP_BUNDLE)/Contents/Resources/"
	codesign --force --deep --sign - --identifier "$(APP_IDENTIFIER)" \
		--requirements '=designated => identifier "$(APP_IDENTIFIER)"' "$(APP_BUNDLE)"
	codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"

$(APP_EXECUTABLE): $(APP_SOURCES) $(APP_HEADERS) $(BUILD_METADATA_HEADER) Resources/Info.plist Makefile
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	clang $(COMMON_FLAGS) $(APP_FRAMEWORKS) $(APP_SOURCES) -o "$(APP_EXECUTABLE)"

build-metadata-test-run:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/BuildMetadataTests -v

release-preparation-test-run:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/ReleasePreparationTests -v

release-transaction-test-run:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/ReleaseTransactionTests -v

model-agent-test-run:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/ModelAgentTests -v

.PHONY: local-model-preflight
local-model-preflight:
	python3 Tools/Release/model_preflight.py

local-model-service-test-run: model-agent-test-run
	mkdir -p .build/tests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/LocalModelServiceController.m \
		Sources/CodexPromptAssistantPOC/Diagnostics.m \
		Tests/CodexPromptAssistantPOCTests/LocalModelServiceControllerTests.m \
		-o .build/tests/LocalModelServiceControllerTests
	.build/tests/LocalModelServiceControllerTests
	.build/tests/LocalModelServiceControllerTests --preserve-resident-model

# Read existing packages only: neither inspection target builds or launches apps.
build-info:
	python3 Tools/BuildMetadata/build_metadata.py --inspect "$(APP_BUNDLE)"

installed-build-info:
	python3 Tools/BuildMetadata/build_metadata.py --inspect "$(INSTALLED_APP_BUNDLE)"

test-run: health-probe-test-run settings-window-test-run completion-quality-harness-test-run application-recovery-test-run application-policy-menu-test-run local-model-service-test-run candidate-lifecycle-test-run
	clang $(TEST_FLAGS) $(APP_FRAMEWORKS) \
		$(filter-out Sources/CodexPromptAssistantPOC/main.m Sources/CodexPromptAssistantPOC/AccessibilityService.m,$(TEST_APP_SOURCES)) \
		Tests/CodexPromptAssistantPOCTests/CodexReadPolicyTests.m -o .build/tests/CodexReadPolicyTests
	.build/tests/CodexReadPolicyTests
	mkdir -p .build/tests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/Diagnostics.m \
		Tests/CodexPromptAssistantPOCTests/DiagnosticsTests.m \
		-o .build/tests/DiagnosticsTests
	.build/tests/DiagnosticsTests
	clang $(TEST_FLAGS) -framework AppKit \
		Sources/CodexPromptAssistantPOC/SuggestionPolicy.m \
		Sources/CodexPromptAssistantPOC/ApplicationMenu.m \
		Tests/CodexPromptAssistantPOCTests/ApplicationMenuTests.m \
		-o .build/tests/ApplicationMenuTests
	.build/tests/ApplicationMenuTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/SuggestionTriggerPolicy.m \
		Tests/CodexPromptAssistantPOCTests/SuggestionTriggerPolicyTests.m \
		-o .build/tests/SuggestionTriggerPolicyTests
	.build/tests/SuggestionTriggerPolicyTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/SuggestionPolicy.m \
		Tests/CodexPromptAssistantPOCTests/SuggestionPolicyTests.m \
		-o .build/tests/SuggestionPolicyTests
	.build/tests/SuggestionPolicyTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/SuggestionPolicy.m \
		Sources/CodexPromptAssistantPOC/SuggestionPolicyStore.m \
		Tests/CodexPromptAssistantPOCTests/SuggestionPolicyStoreTests.m \
		-o .build/tests/SuggestionPolicyStoreTests
	.build/tests/SuggestionPolicyStoreTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/SuggestionPolicy.m \
		Sources/CodexPromptAssistantPOC/InputSceneClassifier.m \
		Tests/CodexPromptAssistantPOCTests/InputSceneClassifierTests.m \
		-o .build/tests/InputSceneClassifierTests
	.build/tests/InputSceneClassifierTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/SuggestionPolicy.m \
		Sources/CodexPromptAssistantPOC/InputSceneClassifier.m \
		Sources/CodexPromptAssistantPOC/ApplicationInputAdapter.m \
		Tests/CodexPromptAssistantPOCTests/ApplicationInputAdapterTests.m \
		-o .build/tests/ApplicationInputAdapterTests
	.build/tests/ApplicationInputAdapterTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/SuggestionPolicy.m \
		Sources/CodexPromptAssistantPOC/SuggestionPolicyStore.m \
		Sources/CodexPromptAssistantPOC/InputSceneClassifier.m \
		Sources/CodexPromptAssistantPOC/ApplicationInputAdapter.m \
		Sources/CodexPromptAssistantPOC/SuggestionPolicyCoordinator.m \
		Sources/CodexPromptAssistantPOC/SuggestionTriggerPolicy.m \
		Tests/CodexPromptAssistantPOCTests/SuggestionPolicyCoordinatorTests.m \
		-o .build/tests/SuggestionPolicyCoordinatorTests
	.build/tests/SuggestionPolicyCoordinatorTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/SuggestionPolicy.m \
		Sources/CodexPromptAssistantPOC/SuggestionPolicyStore.m \
		Sources/CodexPromptAssistantPOC/InputSceneClassifier.m \
		Sources/CodexPromptAssistantPOC/ApplicationInputAdapter.m \
		Sources/CodexPromptAssistantPOC/SuggestionPolicyCoordinator.m \
		Sources/CodexPromptAssistantPOC/SuggestionTriggerPolicy.m \
		Sources/CodexPromptAssistantPOC/SafeInputContextCollector.m \
		Tests/CodexPromptAssistantPOCTests/SafeInputContextCollectorTests.m \
		-o .build/tests/SafeInputContextCollectorTests
	.build/tests/SafeInputContextCollectorTests
	clang $(TEST_FLAGS) -framework AppKit -framework ApplicationServices \
		Sources/CodexPromptAssistantPOC/SuggestionPolicy.m \
		Sources/CodexPromptAssistantPOC/SuggestionPolicyStore.m \
		Sources/CodexPromptAssistantPOC/SafeInputContextCollector.m \
		Sources/CodexPromptAssistantPOC/InputElementIdentity.m Sources/CodexPromptAssistantPOC/GenericAccessibilityService.m Sources/CodexPromptAssistantPOC/WorkBuddyContextReader.m Sources/CodexPromptAssistantPOC/WPSInputBridge.m \
		Tests/CodexPromptAssistantPOCTests/GenericAccessibilityServiceTests.m \
		-o .build/tests/GenericAccessibilityServiceTests
	.build/tests/GenericAccessibilityServiceTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/SuggestionContextIdentity.m \
		Tests/CodexPromptAssistantPOCTests/SuggestionContextIdentityTests.m \
		-o .build/tests/SuggestionContextIdentityTests
	.build/tests/SuggestionContextIdentityTests
	clang $(TEST_FLAGS) -framework AppKit -framework QuartzCore \
		Sources/CodexPromptAssistantPOC/OverlayController.m \
		Sources/CodexPromptAssistantPOC/Diagnostics.m \
		Tests/CodexPromptAssistantPOCTests/OverlayControllerTests.m \
		-o .build/tests/OverlayControllerTests
	.build/tests/OverlayControllerTests
	clang $(TEST_FLAGS) $(DATA_CORE_FRAMEWORKS) \
		$(TEST_DATA_CORE_SOURCES) \
		$(EXPRESSION_LIBRARY_SOURCES) \
		Sources/CodexPromptAssistantPOC/DataFoundationController.m \
		Tests/CodexPromptAssistantPOCTests/DataFoundationControllerTests.m \
		-o .build/tests/DataFoundationControllerTests
	.build/tests/DataFoundationControllerTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/AccessibilitySnapshot.m \
		Tests/CodexPromptAssistantPOCTests/AccessibilitySnapshotTests.m \
		-o .build/tests/AccessibilitySnapshotTests
	.build/tests/AccessibilitySnapshotTests
	clang $(TEST_FLAGS) -framework Foundation \
		Tests/CodexPromptAssistantPOCTests/AccessibilityRoutingTests.m \
		-o .build/tests/AccessibilityRoutingTests
	.build/tests/AccessibilityRoutingTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/AccessibilitySnapshot.m \
		Sources/CodexPromptAssistantPOC/AccessibilitySnapshotBroker.m \
		Tests/CodexPromptAssistantPOCTests/AccessibilitySnapshotBrokerTests.m \
		-o .build/tests/AccessibilitySnapshotBrokerTests
	.build/tests/AccessibilitySnapshotBrokerTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/KeyboardShadowBuffer.m \
		Tests/CodexPromptAssistantPOCTests/KeyboardShadowBufferTests.m \
		-o .build/tests/KeyboardShadowBufferTests
	.build/tests/KeyboardShadowBufferTests
	clang $(TEST_FLAGS) $(APP_FRAMEWORKS) \
		Sources/CodexPromptAssistantPOC/KeyboardShadowBuffer.m \
		Sources/CodexPromptAssistantPOC/InputMethodState.m \
		Sources/CodexPromptAssistantPOC/CandidateWindowClassifier.m \
		Sources/CodexPromptAssistantPOC/Diagnostics.m \
		Tests/CodexPromptAssistantPOCTests/KeyboardInterceptorLifecycleTests.m \
		-o .build/tests/KeyboardInterceptorLifecycleTests
	.build/tests/KeyboardInterceptorLifecycleTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/AccessibilitySnapshot.m \
		Sources/CodexPromptAssistantPOC/InputElementIdentity.m Sources/CodexPromptAssistantPOC/LocalSuggestionCoordinator.m \
		Tests/CodexPromptAssistantPOCTests/LocalSuggestionCoordinatorTests.m \
		-o .build/tests/LocalSuggestionCoordinatorTests
	.build/tests/LocalSuggestionCoordinatorTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/PromptDraftCompleter.m \
		Tests/CodexPromptAssistantPOCTests/PromptDraftCompleterTests.m \
		-o .build/tests/PromptDraftCompleterTests
	.build/tests/PromptDraftCompleterTests
	clang $(TEST_FLAGS) -framework Foundation -framework Carbon \
		Sources/CodexPromptAssistantPOC/InputMethodState.m \
		Tests/CodexPromptAssistantPOCTests/InputMethodStateTests.m \
		-o .build/tests/InputMethodStateTests
	.build/tests/InputMethodStateTests
	clang $(TEST_FLAGS) -framework Foundation -framework CoreGraphics \
		Sources/CodexPromptAssistantPOC/CandidateWindowClassifier.m \
		Tests/CodexPromptAssistantPOCTests/CandidateWindowClassifierTests.m \
		-o .build/tests/CandidateWindowClassifierTests
	.build/tests/CandidateWindowClassifierTests
	clang $(TEST_FLAGS) -framework Foundation -lsqlite3 \
		Sources/CodexPromptAssistantPOC/ConversationContextProvider.m \
		Tests/CodexPromptAssistantPOCTests/ConversationContextProviderTests.m \
		-o .build/tests/ConversationContextProviderTests
	.build/tests/ConversationContextProviderTests

application-recovery-test-run:
	mkdir -p .build/tests
	clang $(TEST_FLAGS) -framework Foundation \
		Tests/CodexPromptAssistantPOCTests/ApplicationRecoveryTests.m \
		-o .build/tests/ApplicationRecoveryTests
	.build/tests/ApplicationRecoveryTests

data-core-test-run: test-data-rebuild
	mkdir -p .build/tests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexDataCore/JSONLLineReader.m \
		Tests/CodexDataCoreTests/JSONLLineReaderTests.m \
		-o .build/tests/JSONLLineReaderTests
	.build/tests/JSONLLineReaderTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexDataCore/CodexSourceMetadata.m \
		Sources/CodexDataCore/CodexMessage.m \
		Sources/CodexDataCore/CodexRecordParser.m \
		Tests/CodexDataCoreTests/CodexRecordParserTests.m \
		-o .build/tests/CodexRecordParserTests
	.build/tests/CodexRecordParserTests
	clang $(TEST_FLAGS) $(DATA_CORE_FRAMEWORKS) $(TEST_DATA_CORE_SOURCES) \
		Tests/CodexDataCoreTests/CodexSourceScannerTests.m \
		-o .build/tests/CodexSourceScannerTests
	.build/tests/CodexSourceScannerTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexDataCore/SensitiveTextRedactor.m \
		Tests/CodexDataCoreTests/SensitiveTextRedactorTests.m \
		-o .build/tests/SensitiveTextRedactorTests
	.build/tests/SensitiveTextRedactorTests
	clang $(TEST_FLAGS) -framework Foundation -framework Security -framework LocalAuthentication \
		Sources/CodexDataCore/MessageCrypto.m \
		Tests/Support/FixtureKeychainStore.m \
		Tests/CodexDataCoreTests/CryptoEnvelopeTests.m \
		-o .build/tests/CryptoEnvelopeTests
	.build/tests/CryptoEnvelopeTests
	clang $(TEST_FLAGS) $(DATA_CORE_FRAMEWORKS) $(TEST_DATA_CORE_SOURCES) \
		Tests/CodexDataCoreTests/LocalDataStoreTests.m \
		-o .build/tests/LocalDataStoreTests
	.build/tests/LocalDataStoreTests
	clang $(TEST_FLAGS) $(DATA_CORE_FRAMEWORKS) $(TEST_DATA_CORE_SOURCES) \
		Tests/CodexDataCoreTests/CodexIncrementalImporterTests.m \
		-o .build/tests/CodexIncrementalImporterTests
	.build/tests/CodexIncrementalImporterTests
	clang $(TEST_FLAGS) $(DATA_CORE_FRAMEWORKS) $(TEST_DATA_CORE_SOURCES) \
		Tests/CodexDataCoreTests/CodexDataRebuildTests.m \
		-o .build/tests/CodexDataRebuildTests
	.build/tests/CodexDataRebuildTests
	clang $(TEST_FLAGS) $(DATA_CORE_FRAMEWORKS) -lz \
		$(TEST_DATA_CORE_SOURCES) $(CHATGPT_IMPORT_SOURCES) \
		Tests/ChatGPTImportCoreTests/ChatGPTExportImporterTests.m \
		-o .build/tests/ChatGPTExportImporterTests
	.build/tests/ChatGPTExportImporterTests
	$(MAKE) master-key-file-test-run

master-key-file-test-run:
	mkdir -p .build/tests
	clang $(TEST_FLAGS) -framework Foundation \
		-framework Security \
		Sources/CodexDataCore/MessageCrypto.m \
		Sources/CodexDataCore/MasterKeyFileStore.m \
		Tests/CodexDataCoreTests/MasterKeyFileStoreTests.m \
		-o .build/tests/MasterKeyFileStoreTests
	.build/tests/MasterKeyFileStoreTests

expression-library-test-run:
	mkdir -p .build/tests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/ExpressionLibraryCore/ExpressionExtractor.m \
		Tests/ExpressionLibraryCoreTests/ExpressionExtractorTests.m \
		-o .build/tests/ExpressionExtractorTests
	.build/tests/ExpressionExtractorTests
	clang $(TEST_FLAGS) $(DATA_CORE_FRAMEWORKS) $(TEST_DATA_CORE_SOURCES) \
		$(EXPRESSION_LIBRARY_SOURCES) \
		Tests/ExpressionLibraryCoreTests/ExpressionLibraryBuilderTests.m \
		-o .build/tests/ExpressionLibraryBuilderTests
	.build/tests/ExpressionLibraryBuilderTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexDataCore/LocalExpressionRecord.m \
		Sources/ExpressionLibraryCore/ExpressionSuggestionIndex.m \
		Tests/ExpressionLibraryCoreTests/ExpressionSuggestionIndexTests.m \
		-o .build/tests/ExpressionSuggestionIndexTests
	.build/tests/ExpressionSuggestionIndexTests

remote-completion-test-run:
	mkdir -p .build/tests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/RemoteCompletionCore/RemoteCompletionSpeculation.m \
		Tests/RemoteCompletionCoreTests/RemoteCompletionSpeculationTests.m \
		-o .build/tests/RemoteCompletionSpeculationTests
	.build/tests/RemoteCompletionSpeculationTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexDataCore/SensitiveTextRedactor.m \
		Sources/RemoteCompletionCore/RemoteCompletionProtocol.m \
		Tests/RemoteCompletionCoreTests/RemoteCompletionProtocolTests.m \
		-o .build/tests/RemoteCompletionProtocolTests
	.build/tests/RemoteCompletionProtocolTests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexDataCore/SensitiveTextRedactor.m \
		Sources/RemoteCompletionCore/RemoteCompletionProtocol.m \
		Sources/RemoteCompletionCore/RemoteCompletionClient.m \
		Tests/RemoteCompletionCoreTests/RemoteCompletionClientTests.m \
		-o .build/tests/RemoteCompletionClientTests
	.build/tests/RemoteCompletionClientTests
	clang $(TEST_FLAGS) -framework Foundation -framework Security -framework LocalAuthentication \
		Tests/Support/FixtureKeychainStore.m \
		Sources/CodexDataCore/MessageCrypto.m \
		Sources/CodexDataCore/MasterKeyFileStore.m \
		Sources/CodexDataCore/RemoteAPIKeyFileStore.m \
		Sources/CodexPromptAssistantPOC/RemoteCompletionSettings.m \
		Tests/CodexPromptAssistantPOCTests/RemoteCompletionSettingsTests.m \
		-o .build/tests/RemoteCompletionSettingsTests
	.build/tests/RemoteCompletionSettingsTests
	clang $(TEST_FLAGS) -framework Foundation -framework Security \
		Sources/CodexDataCore/MessageCrypto.m \
		Sources/CodexDataCore/MasterKeyFileStore.m \
		Sources/CodexDataCore/RemoteAPIKeyFileStore.m \
		Tests/CodexPromptAssistantPOCTests/RemoteAPIKeyFileStoreTests.m \
		-o .build/tests/RemoteAPIKeyFileStoreTests
	.build/tests/RemoteAPIKeyFileStoreTests

checkpoint-c-test-run:
	mkdir -p .build/tests
	clang $(TEST_FLAGS) $(DATA_CORE_FRAMEWORKS) $(TEST_DATA_CORE_SOURCES) \
		Tests/CheckpointCTests/CheckpointCPerformanceTests.m \
		-o .build/tests/CheckpointCPerformanceTests
	.build/tests/CheckpointCPerformanceTests

phase2-checkpoint-test-run:
	mkdir -p .build/tests
	clang $(TEST_FLAGS) $(DATA_CORE_FRAMEWORKS) $(TEST_DATA_CORE_SOURCES) \
		$(EXPRESSION_LIBRARY_SOURCES) \
		Tests/Phase2CheckpointTests/Phase2ExpressionPerformanceTests.m \
		-o .build/tests/Phase2ExpressionPerformanceTests
	.build/tests/Phase2ExpressionPerformanceTests

history-probe:
	mkdir -p build
	clang $(COMMON_FLAGS) $(DATA_CORE_FRAMEWORKS) $(DATA_CORE_SOURCES) \
		Tools/CodexHistoryProbe/main.m \
		-o build/CodexHistoryProbe

crypto-probe:
	mkdir -p build
	clang $(COMMON_FLAGS) -framework Foundation -framework Security -framework LocalAuthentication \
		Sources/CodexDataCore/MessageCrypto.m \
		Sources/CodexDataCore/KeychainStore.m \
		Tools/CryptoProbe/main.m \
		-o build/CryptoProbe

data-rebuild:
	mkdir -p build
	clang $(COMMON_FLAGS) $(DATA_CORE_FRAMEWORKS) $(DATA_CORE_SOURCES) \
		Tools/CodexDataRebuild/main.m \
		-o build/CodexDataRebuild

local-model-benchmark:
	mkdir -p build
	clang $(COMMON_FLAGS) -framework Foundation \
		Sources/CodexDataCore/SensitiveTextRedactor.m \
		Sources/RemoteCompletionCore/RemoteCompletionProtocol.m \
		Sources/RemoteCompletionCore/RemoteCompletionClient.m \
		Tools/LocalModelBenchmark/main.m \
		-o build/LocalModelBenchmark
	build/LocalModelBenchmark

prompt-assistant-service-install: app
	mkdir -p "$(HOME)/Applications"
	mkdir -p "$(HOME)/Library/LaunchAgents"
	/usr/bin/ditto "$(APP_BUNDLE)" "$(INSTALLED_APP_BUNDLE)"
	install -m 600 Resources/local.codex.prompt-assistant-app.plist \
		"$(APP_SERVICE_PLIST)"
	codesign --verify --deep --strict --verbose=2 "$(INSTALLED_APP_BUNDLE)"
	plutil -lint "$(APP_SERVICE_PLIST)"

prompt-assistant-service-start: app
	-launchctl bootout "gui/$$(id -u)/$(APP_SERVICE_LABEL)"
	$(MAKE) prompt-assistant-service-install
	launchctl bootstrap "gui/$$(id -u)" "$(APP_SERVICE_PLIST)"

prompt-assistant-service-stop:
	-launchctl bootout "gui/$$(id -u)/$(APP_SERVICE_LABEL)"

prompt-assistant-service-status:
	launchctl print "gui/$$(id -u)/$(APP_SERVICE_LABEL)"

local-model-service-install:
	python3 Tools/Release/model_agent.py install

local-model-service-start: local-model-service-install
	-launchctl bootout "gui/$$(id -u)/local.codex.prompt-assistant-model"
	sleep 1
	launchctl bootstrap "gui/$$(id -u)" \
		"$$HOME/Library/LaunchAgents/local.codex.prompt-assistant-model.plist"

local-model-service-stop:
	-launchctl bootout "gui/$$(id -u)/local.codex.prompt-assistant-model"

clean:
	rm -R .build build

.PHONY: application-policy-menu-test
candidate-lifecycle-test-run: $(BUILD_METADATA_HEADER)
	mkdir -p .build/tests
	clang $(TEST_FLAGS) $(APP_FRAMEWORKS) \
		$(filter-out Sources/CodexPromptAssistantPOC/main.m,$(TEST_APP_SOURCES)) \
		Tests/CodexPromptAssistantPOCTests/CandidateLifecycleTests.m \
		-o .build/tests/CandidateLifecycleTests
	.build/tests/CandidateLifecycleTests

application-policy-menu-test-run: $(BUILD_METADATA_HEADER)
	mkdir -p .build/tests
	clang $(TEST_FLAGS) $(APP_FRAMEWORKS) \
		$(filter-out Sources/CodexPromptAssistantPOC/main.m,$(TEST_APP_SOURCES)) \
		Tests/CodexPromptAssistantPOCTests/ApplicationPolicyMenuIntegrationTests.m \
		-o .build/tests/ApplicationPolicyMenuIntegrationTests
	.build/tests/ApplicationPolicyMenuIntegrationTests

.PHONY: completion-quality-benchmark
# Synthetic drafts only; default uses the resident model. CPA_BENCHMARK_REMOTE=1
# explicitly uses the configured remote provider and its existing credentials.
completion-quality-benchmark: build/CompletionQualityBenchmark
	build/CompletionQualityBenchmark

build/CompletionQualityBenchmark: Tools/CompletionQualityBenchmark/AuditSupport.m Tools/CompletionQualityBenchmark/AuditSupport.h Tools/CompletionQualityBenchmark/main.m Tools/CompletionQualityBenchmark/BenchmarkSupport.m Tools/CompletionQualityBenchmark/BenchmarkSupport.h $(REMOTE_COMPLETION_SOURCES) $(DATA_CORE_SOURCES) Sources/CodexPromptAssistantPOC/RemoteCompletionSettings.m Sources/CodexPromptAssistantPOC/RemoteCompletionSettings.h
	mkdir -p build
	clang $(COMMON_FLAGS) $(DATA_CORE_FRAMEWORKS) \
		Sources/CodexDataCore/SensitiveTextRedactor.m $(REMOTE_COMPLETION_SOURCES) \
		Sources/CodexDataCore/KeychainStore.m Sources/CodexDataCore/MasterKeyFileStore.m \
		Sources/CodexDataCore/RemoteAPIKeyFileStore.m Sources/CodexDataCore/MessageCrypto.m \
		Sources/CodexPromptAssistantPOC/RemoteCompletionSettings.m \
		Tools/CompletionQualityBenchmark/main.m Tools/CompletionQualityBenchmark/BenchmarkSupport.m Tools/CompletionQualityBenchmark/AuditSupport.m -o build/CompletionQualityBenchmark

.PHONY: wps-bridge-test wps-bridge-install
wps-bridge-test-run:
	node Tests/WPSBridgeTests/bridge.test.js
wps-bridge-install:
	python3 Integrations/WPS/install.py

# Offline suites run serially: existing targets share .build/tests outputs.
# Each public suite gets one sandbox; macOS rejects nested sandbox-exec.
.PHONY: check check-offline check-offline-suites check-performance help
check: check-offline

check-offline:
	@printf 'Offline checks: build identity, app, data, expressions, completion stubs, WPS stubs (network denied)\n'
	$(MAKE) check-offline-suites
	@printf 'PASS: all offline suites; live UI and model quality are not covered\n'

check-offline-suites:
	$(MAKE) test-isolation-test
	$(MAKE) build-metadata-test
	$(MAKE) release-preparation-test
	$(MAKE) release-transaction-test
	$(MAKE) test
	$(MAKE) data-core-test
	$(MAKE) expression-library-test
	$(MAKE) remote-completion-test
	$(MAKE) wps-bridge-test

check-performance:
	$(MAKE) checkpoint-c-test
	$(MAKE) phase2-checkpoint-test

help:
	@printf '%s\n' 'check / check-offline: all offline core suites, no model or app reload' 'check-performance: synthetic data/index performance only' 'app: build and sign, no install' 'build-info / installed-build-info: read on-disk identity only' 'local-model-benchmark / completion-quality-benchmark: use resident model' 'Live UI fixtures: Tests/Fixtures/InputSafety/README.md' 'Installation and reload: see docs/development.md before using service targets'

completion-quality-harness-test-run:
	mkdir -p .build/tests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexDataCore/SensitiveTextRedactor.m $(REMOTE_COMPLETION_SOURCES) \
		Tools/CompletionQualityBenchmark/BenchmarkSupport.m Tools/CompletionQualityBenchmark/AuditSupport.m \
		Tests/RemoteCompletionCoreTests/CompletionQualityHarnessTests.m -o .build/tests/CompletionQualityHarnessTests
	.build/tests/CompletionQualityHarnessTests
	PYTHONDONTWRITEBYTECODE=1 python3 Tests/RemoteCompletionCoreTests/benchmark_runner_test.py

settings-window-test-run: $(BUILD_METADATA_HEADER)
	mkdir -p .build/tests
	clang $(TEST_FLAGS) -framework AppKit Sources/CodexPromptAssistantPOC/SettingsWindowController.m Tests/CodexPromptAssistantPOCTests/SettingsWindowTests.m -o .build/tests/SettingsWindowTests
	.build/tests/SettingsWindowTests

health-probe-test-run: $(BUILD_METADATA_HEADER)
	mkdir -p .build/tests
	clang $(TEST_FLAGS) -framework Foundation Sources/CodexPromptAssistantPOC/HealthProbe.m Tests/CodexPromptAssistantPOCTests/HealthProbeTests.m -o .build/tests/HealthProbeTests
	.build/tests/HealthProbeTests

.PHONY: online-scopes-test online-scopes-test-run
online-scopes-test:
	python3 Tools/Testing/run_isolated.py $(MAKE) online-scopes-test-run
online-scopes-test-run:
	mkdir -p .build/tests
	clang $(TEST_FLAGS) -framework Foundation \
		Sources/CodexPromptAssistantPOC/SuggestionPolicy.m Sources/CodexPromptAssistantPOC/SuggestionPolicyStore.m \
		Sources/CodexPromptAssistantPOC/InputSceneClassifier.m Sources/CodexPromptAssistantPOC/ApplicationInputAdapter.m \
		Sources/CodexPromptAssistantPOC/SuggestionPolicyCoordinator.m Sources/CodexPromptAssistantPOC/SuggestionTriggerPolicy.m \
		Sources/CodexPromptAssistantPOC/SafeInputContextCollector.m \
		Tests/CodexPromptAssistantPOCTests/OnlineScopesTests.m -o .build/tests/OnlineScopesTests
	.build/tests/OnlineScopesTests
