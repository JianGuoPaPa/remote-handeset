import SwiftUI
import UIKit

typealias CalculatorSecretSubmitHandler = @MainActor (String) async -> Void

struct CalculatorView: View {
    private let onSecretSubmit: CalculatorSecretSubmitHandler

    @State private var calculator = CalculatorEngine()
    @State private var isSubmittingSecret = false

    init(onSecretSubmit: @escaping CalculatorSecretSubmitHandler) {
        self.onSecretSubmit = onSecretSubmit
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = CalculatorLayoutMetrics(size: proxy.size)

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: metrics.displayToKeypadSpacing) {
                    Spacer(minLength: metrics.topSpacing)

                    display
                        .frame(width: metrics.keypadWidth, height: metrics.displayHeight)

                    keypad(metrics: metrics)

                    Spacer(minLength: metrics.bottomSpacing)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var display: some View {
        Text(calculator.displayText)
            .font(.system(size: 88, weight: .light, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.32)
            .allowsTightening(true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 22)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        performKeyFeedback()
                        calculator.backspace()
                    }
            )
            .accessibilityLabel("Display")
            .accessibilityValue(calculator.displayText)
            .accessibilityAction(named: "Delete last digit") {
                calculator.backspace()
            }
    }

    private func keypad(metrics: CalculatorLayoutMetrics) -> some View {
        VStack(spacing: metrics.keySpacing) {
            keyRow(metrics: metrics) {
                CalculatorKeyButton(
                    title: calculator.clearButtonTitle,
                    style: .function,
                    metrics: metrics,
                    accessibilityLabel: calculator.clearButtonTitle == "C" ? "Clear entry" : "All clear"
                ) {
                    calculator.clear()
                }

                CalculatorKeyButton(
                    title: "±",
                    style: .function,
                    metrics: metrics,
                    accessibilityLabel: "Toggle positive or negative"
                ) {
                    calculator.toggleSign()
                }

                CalculatorKeyButton(
                    title: "%",
                    style: .function,
                    metrics: metrics,
                    accessibilityLabel: "Percent"
                ) {
                    calculator.applyPercent()
                }

                operationButton(.divide, metrics: metrics)
            }

            keyRow(metrics: metrics) {
                digitButton(7, metrics: metrics)
                digitButton(8, metrics: metrics)
                digitButton(9, metrics: metrics)
                operationButton(.multiply, metrics: metrics)
            }

            keyRow(metrics: metrics) {
                digitButton(4, metrics: metrics)
                digitButton(5, metrics: metrics)
                digitButton(6, metrics: metrics)
                operationButton(.subtract, metrics: metrics)
            }

            keyRow(metrics: metrics) {
                digitButton(1, metrics: metrics)
                digitButton(2, metrics: metrics)
                digitButton(3, metrics: metrics)
                operationButton(.add, metrics: metrics)
            }

            keyRow(metrics: metrics) {
                CalculatorKeyButton(
                    title: "0",
                    style: .digit,
                    metrics: metrics,
                    width: metrics.doubleKeyWidth,
                    isWide: true,
                    accessibilityLabel: "Zero"
                ) {
                    calculator.inputDigit(0)
                }

                CalculatorKeyButton(
                    title: ".",
                    style: .digit,
                    metrics: metrics,
                    accessibilityLabel: "Decimal point"
                ) {
                    calculator.inputDecimalPoint()
                }

                CalculatorKeyButton(
                    title: "=",
                    style: .operation,
                    metrics: metrics,
                    accessibilityLabel: "Equals"
                ) {
                    let submittedValue = calculator.evaluate()
                    submitSecretCandidate(submittedValue)
                }
            }
        }
        .frame(width: metrics.keypadWidth)
    }

    private func keyRow<Content: View>(
        metrics: CalculatorLayoutMetrics,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: metrics.keySpacing, content: content)
    }

    private func digitButton(_ digit: Int, metrics: CalculatorLayoutMetrics) -> some View {
        CalculatorKeyButton(
            title: String(digit),
            style: .digit,
            metrics: metrics,
            accessibilityLabel: String(digit)
        ) {
            calculator.inputDigit(digit)
        }
    }

    private func operationButton(
        _ operation: CalculatorEngine.BinaryOperation,
        metrics: CalculatorLayoutMetrics
    ) -> some View {
        CalculatorKeyButton(
            title: operation.symbol,
            style: .operation,
            metrics: metrics,
            isSelected: calculator.activeOperation == operation,
            accessibilityLabel: operation.accessibilityLabel
        ) {
            calculator.selectOperation(operation)
        }
    }

    private func submitSecretCandidate(_ candidate: String) {
        guard !candidate.isEmpty, !isSubmittingSecret else { return }
        isSubmittingSecret = true

        Task { @MainActor in
            await onSecretSubmit(candidate)
            isSubmittingSecret = false
        }
    }

    private func performKeyFeedback() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
    }
}

private struct CalculatorLayoutMetrics {
    let keySize: CGFloat
    let keySpacing: CGFloat
    let displayHeight: CGFloat
    let topSpacing: CGFloat
    let bottomSpacing: CGFloat
    let displayToKeypadSpacing: CGFloat

    init(size: CGSize) {
        let horizontalMargin: CGFloat = size.width < 500 ? 16 : 30
        let maximumContentWidth: CGFloat = 560
        let availableWidth = min(maximumContentWidth, max(240, size.width - horizontalMargin * 2))
        let proportionalSpacing = min(16, max(8, availableWidth * 0.026))
        let widthLimitedKeySize = (availableWidth - proportionalSpacing * 3) / 4

        let topSpacing = min(28, max(8, size.height * 0.025))
        let bottomSpacing = min(24, max(8, size.height * 0.018))
        let displayHeight = min(190, max(74, size.height * 0.22))
        let displayToKeypadSpacing = min(20, max(8, size.height * 0.015))
        let verticalFixedSpace = topSpacing + bottomSpacing + displayHeight + displayToKeypadSpacing
        let heightLimitedKeySize = max(42, (size.height - verticalFixedSpace - proportionalSpacing * 4) / 5)

        self.keySize = min(widthLimitedKeySize, heightLimitedKeySize)
        self.keySpacing = proportionalSpacing
        self.displayHeight = displayHeight
        self.topSpacing = topSpacing
        self.bottomSpacing = bottomSpacing
        self.displayToKeypadSpacing = displayToKeypadSpacing
    }

    var doubleKeyWidth: CGFloat {
        keySize * 2 + keySpacing
    }

    var keypadWidth: CGFloat {
        keySize * 4 + keySpacing * 3
    }
}

private struct CalculatorKeyButton: View {
    enum KeyStyle {
        case digit
        case function
        case operation
    }

    let title: String
    let style: KeyStyle
    let metrics: CalculatorLayoutMetrics
    var width: CGFloat?
    var isWide = false
    var isSelected = false
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
            action()
        } label: {
            Text(title)
                .font(.system(size: metrics.keySize * 0.39, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(foregroundColor)
                .offset(x: isWide ? metrics.keySize * 0.38 : 0)
                .frame(width: width ?? metrics.keySize, height: metrics.keySize, alignment: isWide ? .leading : .center)
                .background(backgroundColor)
                .clipShape(Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(CalculatorKeyPressStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foregroundColor: Color {
        switch style {
        case .digit:
            .white
        case .function:
            .black
        case .operation:
            isSelected ? Color.orange : .white
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .digit:
            Color(white: 0.20)
        case .function:
            Color(white: 0.65)
        case .operation:
            isSelected ? .white : .orange
        }
    }
}

private struct CalculatorKeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.18 : 0)
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private extension CalculatorEngine.BinaryOperation {
    var accessibilityLabel: String {
        switch self {
        case .divide: "Divide"
        case .multiply: "Multiply"
        case .subtract: "Subtract"
        case .add: "Add"
        }
    }
}
