#if APKRUN_EMBEDDED_RUNTIME
    import Foundation

    enum DevDisplaysInput: Equatable {
        case add(width: Int, height: Int, dpi: Int)
        case list
        case remove(scanout: Int)
        case help
        case quit
        case empty
    }

    enum DevDisplaysInputParser {
        static func parse(_ line: String) throws -> DevDisplaysInput {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let command = tokens.first else {
                return .empty
            }
            switch command {
            case "add":
                var size: (width: Int, height: Int)?
                var dpi: Int?
                var index = 1
                while index < tokens.count {
                    switch tokens[index] {
                    case "--size":
                        guard size == nil, tokens.indices.contains(index + 1),
                            let parsed = parseSize(tokens[index + 1])
                        else {
                            throw CLIFailure.invalidArgument(argument: "--size", reason: "displaySize")
                        }
                        size = parsed
                        index += 2
                    case "--dpi":
                        guard dpi == nil, tokens.indices.contains(index + 1),
                            let parsed = Int(tokens[index + 1]), (120...640).contains(parsed)
                        else {
                            throw CLIFailure.invalidArgument(argument: "--dpi", reason: "range")
                        }
                        dpi = parsed
                        index += 2
                    default:
                        throw CLIFailure.invalidArgument(argument: tokens[index], reason: "displayCommand")
                    }
                }
                guard let size, let dpi else {
                    throw CLIFailure.invalidArgument(argument: "add", reason: "displaySizeAndDensityRequired")
                }
                return .add(width: size.width, height: size.height, dpi: dpi)
            case "list":
                guard tokens.count == 1 else {
                    throw CLIFailure.invalidArgument(argument: "list", reason: "displayCommand")
                }
                return .list
            case "remove":
                guard tokens.count == 2, let scanout = Int(tokens[1]), (1...15).contains(scanout) else {
                    throw CLIFailure.invalidArgument(argument: "remove", reason: "scanout")
                }
                return .remove(scanout: scanout)
            case "help":
                guard tokens.count == 1 else {
                    throw CLIFailure.invalidArgument(argument: "help", reason: "displayCommand")
                }
                return .help
            case "quit", "exit":
                guard tokens.count == 1 else {
                    throw CLIFailure.invalidArgument(argument: command, reason: "displayCommand")
                }
                return .quit
            default:
                throw CLIFailure.invalidArgument(argument: command, reason: "displayCommand")
            }
        }

        private static func parseSize(_ value: String) -> (width: Int, height: Int)? {
            let dimensions = value.split(separator: "x", omittingEmptySubsequences: false)
            guard dimensions.count == 2,
                let width = Int(dimensions[0]), width >= 640,
                let height = Int(dimensions[1]), height >= 800
            else {
                return nil
            }
            return (width, height)
        }
    }
#endif
