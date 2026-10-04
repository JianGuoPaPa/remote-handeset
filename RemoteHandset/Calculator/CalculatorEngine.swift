import Foundation

struct CalculatorEngine {
    enum BinaryOperation: Equatable {
        case divide
        case multiply
        case subtract
        case add

        var symbol: String {
            switch self {
            case .divide: "÷"
            case .multiply: "×"
            case .subtract: "−"
            case .add: "+"
            }
        }
    }

    private static let maximumInputDigits = 32
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private(set) var displayText = "0"
    private(set) var activeOperation: BinaryOperation?

    private var accumulator: Decimal?
    private var pendingOperation: BinaryOperation?
    private var repeatedOperation: BinaryOperation?
    private var repeatedOperand: Decimal?
    private var isEnteringNumber = false
    private var replacesDisplayOnDigit = true
    private var hasError = false
    private var hasJustEvaluated = false
    private var submissionBuffer = ""

    var clearButtonTitle: String {
        isEnteringNumber && !hasJustEvaluated ? "C" : "AC"
    }

    mutating func inputDigit(_ digit: Int) {
        guard (0...9).contains(digit) else { return }
        prepareForFreshCalculationIfNeeded()

        let character = String(digit)
        let numberOfDigits = displayText.lazy.filter(\.isNumber).count
        guard replacesDisplayOnDigit || numberOfDigits < Self.maximumInputDigits else { return }

        if replacesDisplayOnDigit {
            displayText = character
            replacesDisplayOnDigit = false
        } else if displayText == "0" {
            displayText = character
        } else if displayText == "-0" {
            displayText = "-" + character
        } else {
            displayText.append(character)
        }

        submissionBuffer.append(character)
        isEnteringNumber = true
        hasJustEvaluated = false
    }

    mutating func inputDecimalPoint() {
        prepareForFreshCalculationIfNeeded()

        if replacesDisplayOnDigit {
            displayText = "0."
            replacesDisplayOnDigit = false
            submissionBuffer.append("0.")
        } else if !displayText.contains(".") {
            displayText.append(".")
            submissionBuffer.append(".")
        }

        isEnteringNumber = true
        hasJustEvaluated = false
    }

    mutating func toggleSign() {
        guard !hasError else { return }

        if hasJustEvaluated {
            if displayText.hasPrefix("-") {
                displayText.removeFirst()
            } else if displayText != "0" {
                displayText.insert("-", at: displayText.startIndex)
            }
            accumulator = decimalValue(from: displayText)
            submissionBuffer = displayText
            return
        }

        if replacesDisplayOnDigit {
            displayText = "-0"
            replacesDisplayOnDigit = false
            isEnteringNumber = true
        } else if displayText.hasPrefix("-") {
            displayText.removeFirst()
        } else if displayText != "0" {
            displayText.insert("-", at: displayText.startIndex)
        }

        submissionBuffer.append("±")
        hasJustEvaluated = false
    }

    mutating func applyPercent() {
        guard !hasError, let currentValue = decimalValue(from: displayText) else { return }

        let percentValue: Decimal?
        if let pendingOperation,
           (pendingOperation == .add || pendingOperation == .subtract),
           let accumulator {
            percentValue = calculate(
                calculate(accumulator, .multiply, currentValue),
                .divide,
                Decimal(100)
            )
        } else {
            percentValue = calculate(currentValue, .divide, Decimal(100))
        }

        guard let percentValue else {
            enterErrorState()
            return
        }

        displayText = format(percentValue)
        if pendingOperation == nil {
            accumulator = percentValue
        }
        replacesDisplayOnDigit = true
        isEnteringNumber = true
        hasJustEvaluated = false
        submissionBuffer.append("%")
    }

    mutating func selectOperation(_ operation: BinaryOperation) {
        guard !hasError, let currentValue = decimalValue(from: displayText) else { return }

        if hasJustEvaluated {
            accumulator = currentValue
            submissionBuffer = displayText
            repeatedOperation = nil
            repeatedOperand = nil
        } else if let pendingOperation, isEnteringNumber, let accumulator {
            guard let result = calculate(accumulator, pendingOperation, currentValue) else {
                enterErrorState()
                return
            }
            self.accumulator = result
            displayText = format(result)
        } else if accumulator == nil {
            accumulator = currentValue
        }

        if !isEnteringNumber, self.pendingOperation != nil {
            replaceTrailingOperation(in: &submissionBuffer, with: operation.symbol)
        } else {
            submissionBuffer.append(operation.symbol)
        }

        pendingOperation = operation
        activeOperation = operation
        repeatedOperation = nil
        repeatedOperand = nil
        isEnteringNumber = false
        replacesDisplayOnDigit = true
        hasJustEvaluated = false
    }

    /// Evaluates the visible calculation and returns the exact key sequence that
    /// preceded the equals key. Callers may use the returned value for an
    /// independent asynchronous action without changing calculator behavior.
    mutating func evaluate() -> String {
        guard !hasError else {
            return ""
        }

        let submittedValue = submissionBuffer.isEmpty ? displayText : submissionBuffer
        guard let currentValue = decimalValue(from: displayText) else {
            enterErrorState()
            return submittedValue
        }

        let result: Decimal
        if let pendingOperation {
            let leftValue = accumulator ?? currentValue
            let rightValue = isEnteringNumber ? currentValue : leftValue
            guard let calculated = calculate(leftValue, pendingOperation, rightValue) else {
                enterErrorState()
                return submittedValue
            }
            result = calculated
            repeatedOperation = pendingOperation
            repeatedOperand = rightValue
        } else if hasJustEvaluated,
                  let repeatedOperation,
                  let repeatedOperand {
            guard let calculated = calculate(currentValue, repeatedOperation, repeatedOperand) else {
                enterErrorState()
                return submittedValue
            }
            result = calculated
        } else {
            result = currentValue
        }

        displayText = format(result)
        accumulator = result
        pendingOperation = nil
        activeOperation = nil
        isEnteringNumber = false
        replacesDisplayOnDigit = true
        hasJustEvaluated = true
        submissionBuffer = displayText
        return submittedValue
    }

    mutating func clear() {
        if isEnteringNumber, !hasJustEvaluated, !hasError {
            displayText = "0"
            isEnteringNumber = false
            replacesDisplayOnDigit = true
            removeCurrentOperandFromSubmissionBuffer()
        } else {
            clearAll()
        }
    }

    mutating func clearAll() {
        displayText = "0"
        activeOperation = nil
        accumulator = nil
        pendingOperation = nil
        repeatedOperation = nil
        repeatedOperand = nil
        isEnteringNumber = false
        replacesDisplayOnDigit = true
        hasError = false
        hasJustEvaluated = false
        submissionBuffer = ""
    }

    mutating func backspace() {
        guard !hasError else {
            clearAll()
            return
        }

        if hasJustEvaluated {
            accumulator = nil
            pendingOperation = nil
            repeatedOperation = nil
            repeatedOperand = nil
            activeOperation = nil
            hasJustEvaluated = false
            isEnteringNumber = true
            replacesDisplayOnDigit = false
            submissionBuffer = displayText
        }

        guard !replacesDisplayOnDigit, isEnteringNumber else { return }

        if displayText.count <= 1 || (displayText.hasPrefix("-") && displayText.count == 2) {
            displayText = "0"
        } else {
            displayText.removeLast()
            if displayText == "-" || displayText.isEmpty {
                displayText = "0"
            }
        }

        if let lastCharacter = submissionBuffer.last,
           lastCharacter.isNumber || lastCharacter == "." {
            submissionBuffer.removeLast()
        }

        if displayText == "0" {
            isEnteringNumber = false
            replacesDisplayOnDigit = true
            if pendingOperation == nil {
                submissionBuffer = ""
            }
        }
    }

    private mutating func prepareForFreshCalculationIfNeeded() {
        if hasError || hasJustEvaluated {
            clearAll()
        }
    }

    private mutating func enterErrorState() {
        displayText = "Error"
        activeOperation = nil
        accumulator = nil
        pendingOperation = nil
        repeatedOperation = nil
        repeatedOperand = nil
        isEnteringNumber = false
        replacesDisplayOnDigit = true
        hasError = true
        hasJustEvaluated = false
        submissionBuffer = ""
    }

    private func decimalValue(from text: String) -> Decimal? {
        Decimal(string: text, locale: Self.posixLocale)
    }

    private func calculate(
        _ leftValue: Decimal?,
        _ operation: BinaryOperation,
        _ rightValue: Decimal
    ) -> Decimal? {
        guard let leftValue else { return nil }
        return calculate(leftValue, operation, rightValue)
    }

    private func calculate(
        _ leftValue: Decimal,
        _ operation: BinaryOperation,
        _ rightValue: Decimal
    ) -> Decimal? {
        if operation == .divide, rightValue == 0 {
            return nil
        }

        var leftValue = leftValue
        var rightValue = rightValue
        var result = Decimal()
        let calculationError: Decimal.CalculationError

        switch operation {
        case .add:
            calculationError = NSDecimalAdd(&result, &leftValue, &rightValue, .bankers)
        case .subtract:
            calculationError = NSDecimalSubtract(&result, &leftValue, &rightValue, .bankers)
        case .multiply:
            calculationError = NSDecimalMultiply(&result, &leftValue, &rightValue, .bankers)
        case .divide:
            calculationError = NSDecimalDivide(&result, &leftValue, &rightValue, .bankers)
        }

        switch calculationError {
        case .noError, .lossOfPrecision:
            return result
        case .underflow, .overflow, .divideByZero:
            return nil
        @unknown default:
            return nil
        }
    }

    private func format(_ value: Decimal) -> String {
        guard value != 0 else { return "0" }

        let number = NSDecimalNumber(decimal: value)
        let magnitude = abs(number.doubleValue)
        guard magnitude.isFinite else { return "Error" }

        let formatter = NumberFormatter()
        formatter.locale = Self.posixLocale
        formatter.usesGroupingSeparator = false
        formatter.roundingMode = .halfEven

        if magnitude >= 1_000_000_000_000_000 || magnitude < 0.000_000_001 {
            formatter.numberStyle = .scientific
            formatter.exponentSymbol = "e"
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 12
        } else {
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 15
            formatter.usesSignificantDigits = true
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 15
        }

        return formatter.string(from: number) ?? number.stringValue
    }

    private func isOperationSymbol(_ character: Character) -> Bool {
        character == "+" || character == "−" || character == "×" || character == "÷"
    }

    private func replaceTrailingOperation(in value: inout String, with symbol: String) {
        if let lastCharacter = value.last, isOperationSymbol(lastCharacter) {
            value.removeLast()
        }
        value.append(symbol)
    }

    private mutating func removeCurrentOperandFromSubmissionBuffer() {
        while let lastCharacter = submissionBuffer.last, !isOperationSymbol(lastCharacter) {
            submissionBuffer.removeLast()
        }
    }
}
