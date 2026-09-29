#!/usr/bin/env python3
"""Enforce APKRun's host logging API and privacy rules."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

SOURCE_SUFFIXES = {".swift", ".m", ".mm", ".h", ".c", ".cc", ".cpp"}
LOGGER_METHODS = {"debug", "info", "notice", "error", "fault"}
LOGGER_METHOD_PATTERN = "|".join(sorted(LOGGER_METHODS))

FORBIDDEN_APIS = (
    ("os.Logger", re.compile(r"(?<![\w.])os\s*\.\s*Logger\b")),
    (
        "Logger(",
        re.compile(r"(?<![\w])Logger\s*(?:\.\s*init)?\s*\("),
    ),
    ("print(", re.compile(r"(?<![\w])print\s*\(")),
    ("NSLog", re.compile(r"(?<![\w])NSLog(?:v)?\b")),
    ("os_log", re.compile(r"(?<![\w])os_log(?:_[A-Za-z0-9_]+)?\b")),
)


@dataclass
class Scope:
    start: int
    end: int
    parent: int | None


@dataclass
class Binding:
    name: str
    position: int
    scope: int
    sensitive: bool = False
    logger: bool = False
    initializer: str | None = None


@dataclass(frozen=True)
class TypeAlias:
    parameters: tuple[str, ...]
    value: str


@dataclass(frozen=True)
class TypeAliasBinding:
    name: str
    alias: TypeAlias
    scope: int


def blank_non_code(source: str) -> str:
    """Mask comments, regex bodies, and string text while retaining interpolation code."""
    output = list(source)
    length = len(source)

    def blank(start: int, end: int) -> None:
        for position in range(start, min(end, length)):
            if output[position] not in "\r\n":
                output[position] = " "

    def string_start(position: int) -> tuple[int, int] | None:
        cursor = position
        hashes = 0
        while cursor < length and source[cursor] == "#":
            hashes += 1
            cursor += 1
        if cursor >= length or source[cursor] != '"':
            return None
        quote_width = 3 if source.startswith('"""', cursor) else 1
        return hashes, quote_width

    def regex_start(position: int) -> int | None:
        if source[position] == "#":
            cursor = position
            while cursor < length and source[cursor] == "#":
                cursor += 1
            return cursor - position if cursor < length and source[cursor] == "/" else None
        if source[position] != "/" or source.startswith(("//", "/*"), position):
            return None
        previous = position - 1
        while previous >= 0 and source[previous].isspace():
            previous -= 1
        if previous < 0 or source[previous] in "=(,[{:;!&|?+-*%^~>":
            return 0
        word_end = previous + 1
        while previous >= 0 and (source[previous].isalnum() or source[previous] == "_"):
            previous -= 1
        return 0 if source[previous + 1 : word_end] in {"return", "throw", "case"} else None

    def scan_comment(position: int) -> int:
        if source.startswith("//", position):
            newline = source.find("\n", position + 2)
            end = length if newline < 0 else newline
            blank(position, end)
            return end

        depth = 1
        cursor = position + 2
        while cursor < length and depth:
            if source.startswith("/*", cursor):
                depth += 1
                cursor += 2
            elif source.startswith("*/", cursor):
                depth -= 1
                cursor += 2
            else:
                cursor += 1
        blank(position, cursor)
        return cursor

    def scan_code(position: int, stop_at_paren: bool = False) -> int:
        depth = 1 if stop_at_paren else 0
        cursor = position
        while cursor < length:
            hashes = regex_start(cursor)
            if hashes is not None:
                cursor = scan_regex(cursor, hashes)
                continue
            if source.startswith("//", cursor) or source.startswith("/*", cursor):
                cursor = scan_comment(cursor)
                continue

            delimiter = string_start(cursor)
            if delimiter is not None:
                cursor = scan_string(cursor, *delimiter)
                continue

            character = source[cursor]
            if stop_at_paren and character == "(":
                depth += 1
            elif stop_at_paren and character == ")":
                depth -= 1
                if depth == 0:
                    return cursor + 1
            cursor += 1
        return cursor

    def scan_string(position: int, hashes: int, quote_width: int) -> int:
        quote_start = position + hashes
        content_start = quote_start + quote_width
        blank(position, content_start)
        cursor = content_start
        segment_start = content_start
        close = '"' * quote_width + "#" * hashes

        while cursor < length:
            if source.startswith(close, cursor):
                blank(segment_start, cursor + len(close))
                return cursor + len(close)

            if source[cursor] == "\\":
                marker = "\\" + "#" * hashes + "("
                if source.startswith(marker, cursor):
                    blank(segment_start, cursor + len(marker) - 1)
                    cursor = scan_code(cursor + len(marker), stop_at_paren=True)
                    segment_start = cursor
                    continue
                escaped_quote = "\\" + "#" * hashes + '"' * quote_width
                if hashes > 0 and source.startswith(escaped_quote, cursor):
                    cursor += len(escaped_quote)
                    continue
                if hashes == 0:
                    cursor += 2
                    continue
            cursor += 1

        blank(segment_start, length)
        return length

    def scan_regex(position: int, hashes: int) -> int:
        delimiter_end = position + hashes + 1
        blank(position, delimiter_end)
        cursor = delimiter_end
        segment_start = cursor
        close = "/" + "#" * hashes
        marker = "\\" + "#" * hashes + "("

        while cursor < length:
            if source.startswith(close, cursor):
                backslashes = 0
                previous = cursor - 1
                while previous >= segment_start and source[previous] == "\\":
                    backslashes += 1
                    previous -= 1
                if backslashes % 2 == 0:
                    blank(segment_start, cursor + len(close))
                    return cursor + len(close)
            if hashes > 0 and source[cursor] == "\\" and source.startswith(marker, cursor):
                blank(segment_start, cursor + len(marker) - 1)
                cursor = scan_code(cursor + len(marker), stop_at_paren=True)
                segment_start = cursor
                continue
            cursor += 1

        blank(segment_start, length)
        return length

    cursor = 0
    while cursor < length:
        hashes = regex_start(cursor)
        if hashes is not None:
            cursor = scan_regex(cursor, hashes)
            continue
        if source.startswith("//", cursor) or source.startswith("/*", cursor):
            cursor = scan_comment(cursor)
            continue
        delimiter = string_start(cursor)
        if delimiter is not None:
            cursor = scan_string(cursor, *delimiter)
            continue
        cursor += 1

    return "".join(output)


def matching_parenthesis(masked: str, opening: int) -> int | None:
    return matching_delimiter(masked, opening, "(", ")")


def matching_delimiter(
    masked: str,
    opening: int,
    opening_character: str,
    closing_character: str,
) -> int | None:
    depth = 0
    for position in range(opening, len(masked)):
        if masked[position] == opening_character:
            depth += 1
        elif masked[position] == closing_character:
            depth -= 1
            if depth == 0:
                return position
    return None


def matching_angle_bracket(source: str, opening: int) -> int | None:
    depth = 0
    for position in range(opening, len(source)):
        character = source[position]
        if character == "<":
            depth += 1
        elif character == ">" and (position == 0 or source[position - 1] != "-"):
            depth -= 1
            if depth == 0:
                return position
    return None


def split_type_arguments(source: str, start: int, end: int) -> list[str]:
    ranges: list[tuple[int, int]] = []
    item_start = start
    depth = {"(": 0, "[": 0, "{": 0, "<": 0}
    closing = {")": "(", "]": "[", "}": "{", ">": "<"}
    for position in range(start, end):
        character = source[position]
        if character in depth:
            depth[character] += 1
        elif character in closing:
            if character == ">" and position > 0 and source[position - 1] == "-":
                continue
            opening = closing[character]
            depth[opening] = max(0, depth[opening] - 1)
        elif character == "," and all(value == 0 for value in depth.values()):
            ranges.append((item_start, position))
            item_start = position + 1
    ranges.append((item_start, end))
    return [source[left:right].strip() for left, right in ranges]


def split_top_level(masked: str, start: int, end: int, delimiter: str) -> list[tuple[int, int]]:
    depths = {"(": 0, "[": 0, "{": 0}
    closing = {")": "(", "]": "[", "}": "{"}
    ranges: list[tuple[int, int]] = []
    item_start = start
    for position in range(start, end):
        character = masked[position]
        if character in depths:
            depths[character] += 1
        elif character in closing:
            opening = closing[character]
            depths[opening] = max(0, depths[opening] - 1)
        elif character == delimiter and all(value == 0 for value in depths.values()):
            ranges.append((item_start, position))
            item_start = position + 1
    ranges.append((item_start, end))
    return ranges


def first_argument_end(masked: str, start: int, end: int) -> int:
    return split_top_level(masked, start, end, ",")[0][1]


def string_literal_interpolations(
    source: str, masked: str, start: int, end: int
) -> list[tuple[int, int]]:
    """Return interpolation expression ranges from the leading message literal."""
    cursor = start
    while cursor < end and source[cursor].isspace():
        cursor += 1
    while cursor < end and source[cursor] == "(":
        cursor += 1
        while cursor < end and source[cursor].isspace():
            cursor += 1

    hashes = 0
    while cursor < end and source[cursor] == "#":
        hashes += 1
        cursor += 1
    if cursor >= end or source[cursor] != '"':
        return []
    quote_width = 3 if source.startswith('"""', cursor) else 1
    cursor += quote_width
    close = '"' * quote_width + "#" * hashes
    ranges: list[tuple[int, int]] = []

    while cursor < end:
        if source.startswith(close, cursor):
            break
        if source[cursor] == "\\":
            marker = "\\" + "#" * hashes + "("
            if source.startswith(marker, cursor):
                opening = cursor + len(marker) - 1
                closing = matching_parenthesis(masked, opening)
                if closing is None or closing >= end:
                    break
                ranges.append((opening + 1, closing))
                cursor = closing + 1
                continue
            escaped_quote = "\\" + "#" * hashes + '"' * quote_width
            if hashes > 0 and source.startswith(escaped_quote, cursor):
                cursor += len(escaped_quote)
                continue
            if hashes == 0:
                cursor += 2
                continue
        cursor += 1
    return ranges


def has_privacy_argument(masked: str) -> bool:
    comma_ranges = split_top_level(masked, 0, len(masked), ",")
    if len(comma_ranges) < 2:
        return False
    last_start, last_end = comma_ranges[-1]
    last_argument = masked[last_start:last_end].strip()
    return re.fullmatch(
        r"(?:\.\s*(?:public|private|hashed)|"
        r"LogPrivacy\s*\.\s*(?:public|private|hashed))",
        last_argument,
    ) is not None


def build_scopes(masked: str) -> tuple[list[Scope], list[int]]:
    scopes = [Scope(start=0, end=len(masked), parent=None)]
    scope_at = [0] * len(masked)
    stack = [0]
    for position, character in enumerate(masked):
        if character == "{":
            child = len(scopes)
            scopes.append(Scope(start=position + 1, end=len(masked), parent=stack[-1]))
            stack.append(child)
            scope_at[position] = child
        elif character == "}":
            scope_at[position] = stack[-1]
            if len(stack) > 1:
                scopes[stack.pop()].end = position
        else:
            scope_at[position] = stack[-1]
    return scopes, scope_at


def ancestor_scopes(scopes: list[Scope], scope: int) -> list[int]:
    ancestors: list[int] = []
    while True:
        ancestors.append(scope)
        parent = scopes[scope].parent
        if parent is None:
            return ancestors
        scope = parent


def resolve_binding(
    name: str,
    position: int,
    scopes: list[Scope],
    scope_at: list[int],
    bindings: list[Binding],
) -> Binding | None:
    if not scope_at:
        return None
    scope = scope_at[min(max(0, position), len(scope_at) - 1)]
    ancestors = ancestor_scopes(scopes, scope)
    for ancestor in ancestors:
        candidates = [
            binding
            for binding in bindings
            if binding.name == name
            and binding.scope == ancestor
            and binding.position <= position
        ]
        if candidates:
            return max(candidates, key=lambda binding: binding.position)
    return None


def collect_type_aliases(
    masked: str,
    scope_at: list[int],
) -> list[TypeAliasBinding]:
    bindings: list[TypeAliasBinding] = []
    for match in re.finditer(
            r"\btypealias\s+(?P<name>[A-Za-z_]\w*)"
            r"(?:\s*<(?P<parameters>[^;\n=]+)>)?\s*=\s*"
            r"(?P<value>[^;\n]+)",
            masked,
    ):
        parameters: list[str] = []
        for parameter in (match.group("parameters") or "").split(","):
            parameter_match = re.match(r"\s*(?:each\s+)?([A-Za-z_]\w*)", parameter)
            if parameter_match:
                parameters.append(parameter_match.group(1))
        bindings.append(
            TypeAliasBinding(
                name=match.group("name"),
                alias=TypeAlias(
                    parameters=tuple(parameters),
                    value=match.group("value").strip(),
                ),
                scope=scope_at[min(match.start(), len(scope_at) - 1)] if scope_at else 0,
            )
        )
    return bindings


def aliases_by_scope(
    declarations: list[TypeAliasBinding],
    scopes: list[Scope],
) -> dict[int, dict[str, TypeAlias]]:
    contexts: dict[int, dict[str, TypeAlias]] = {}
    for scope in range(len(scopes)):
        ancestors = ancestor_scopes(scopes, scope)
        aliases: dict[str, TypeAlias] = {}
        depths: dict[str, int] = {}
        for declaration in declarations:
            if declaration.scope not in ancestors:
                continue
            depth = ancestors.index(declaration.scope)
            if depth < depths.get(declaration.name, len(ancestors)):
                aliases[declaration.name] = declaration.alias
                depths[declaration.name] = depth
        contexts[scope] = aliases
    return contexts


def aliases_for_position(
    aliases: dict[int, dict[str, TypeAlias]],
    scope_at: list[int],
    position: int,
) -> dict[str, TypeAlias]:
    if not aliases:
        return {}
    scope = scope_at[min(max(position, 0), len(scope_at) - 1)] if scope_at else 0
    return aliases.get(scope, {})


def expand_type_aliases(type_text: str, aliases: dict[str, TypeAlias]) -> str:
    expanded = type_text
    for _ in range(len(aliases) + 1):
        output: list[str] = []
        cursor = 0
        while cursor < len(expanded):
            match = re.match(r"[A-Za-z_]\w*", expanded[cursor:])
            if match is None:
                output.append(expanded[cursor])
                cursor += 1
                continue

            name = match.group(0)
            alias = aliases.get(name)
            end = cursor + len(name)
            if alias is None:
                output.append(name)
                cursor = end
                continue

            if alias.parameters:
                arguments_start = end
                while arguments_start < len(expanded) and expanded[arguments_start].isspace():
                    arguments_start += 1
                if arguments_start >= len(expanded) or expanded[arguments_start] != "<":
                    output.append(name)
                    cursor = end
                    continue
                arguments_end = matching_angle_bracket(expanded, arguments_start)
                if arguments_end is None:
                    output.append(name)
                    cursor = end
                    continue
                arguments = split_type_arguments(
                    expanded,
                    arguments_start + 1,
                    arguments_end,
                )
                if len(arguments) != len(alias.parameters):
                    output.append(expanded[cursor : arguments_end + 1])
                    cursor = arguments_end + 1
                    continue
                replacement = alias.value
                for parameter, argument in zip(alias.parameters, arguments):
                    replacement = re.sub(
                        rf"\b{re.escape(parameter)}\b",
                        lambda _: argument,
                        replacement,
                    )
                output.append(replacement)
                cursor = arguments_end + 1
                continue

            output.append(alias.value)
            cursor = end

        previous = expanded
        expanded = "".join(output)
        if expanded == previous:
            break
    return expanded


def is_sensitive_type(type_text: str, aliases: dict[str, TypeAlias]) -> bool:
    expanded = expand_type_aliases(type_text, aliases)
    expanded = re.sub(r"\s*\.\s*", ".", expanded)
    expanded = re.sub(
        r"\b(?:DiagnosticsCore\.)+(?=Sensitive\b)",
        "",
        expanded,
    )
    return re.fullmatch(
        r"\s*(?:any\s+)?Sensitive(?:\s*<[\s\S]*>)?\s*\??\s*",
        expanded,
    ) is not None


def is_logger_type(type_text: str, aliases: dict[str, TypeAlias]) -> bool:
    expanded = expand_type_aliases(type_text, aliases)
    expanded = re.sub(r"\s*\.\s*", ".", expanded)
    expanded = re.sub(
        r"\b(?:DiagnosticsCore\.)+(?=APKLogger\b)",
        "",
        expanded,
    )
    return re.fullmatch(
        r"\s*(?:any\s+)?APKLogger\s*\??\s*",
        expanded,
    ) is not None


def function_parameters(
    masked: str,
    scopes: list[Scope],
    scope_at: list[int],
    aliases: dict[int, dict[str, TypeAlias]],
) -> tuple[list[Binding], set[str]]:
    bindings: list[Binding] = []
    factories: set[str] = set()
    for match in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\b", masked):
        name = match.group(1)
        opening = masked.find("(", match.end())
        if opening < 0:
            continue
        closing = matching_parenthesis(masked, opening)
        if closing is None:
            continue
        function_aliases = aliases_for_position(aliases, scope_at, match.start())
        body_open = masked.find("{", closing + 1)
        if body_open < 0:
            continue
        next_function = masked.find("func ", closing + 1)
        if 0 <= next_function < body_open:
            continue
        signature_tail = masked[closing + 1 : body_open]
        if re.search(r"\n\s*(?:func|var|let|case|associatedtype)\b", signature_tail):
            continue
        return_type = re.search(r"->\s*(.*)", signature_tail, re.S)
        if return_type and is_logger_type(return_type.group(1), function_aliases):
            factories.add(name)

        body_scope = scope_at[min(body_open + 1, len(scope_at) - 1)]
        bindings.extend(
            parameter_bindings(
                masked,
                opening + 1,
                closing,
                body_open + 1,
                body_scope,
                function_aliases,
            )
        )

    for match in re.finditer(r"\{\s*\(", masked):
        opening = masked.find("(", match.start(), match.end())
        closing = matching_parenthesis(masked, opening)
        if closing is None:
            continue
        in_match = re.match(r"\s*in\b", masked[closing + 1 :])
        if in_match is None:
            continue
        body_position = closing + 1 + in_match.end()
        closure_scope = scope_at[min(match.start(), len(scope_at) - 1)]
        closure_aliases = aliases_for_position(aliases, scope_at, match.start())
        bindings.extend(
            parameter_bindings(
                masked,
                opening + 1,
                closing,
                body_position,
                closure_scope,
                closure_aliases,
            )
        )
    bindings.extend(contextual_closure_parameters(masked, scope_at, aliases))
    return bindings, factories


def contextual_closure_parameters(
    masked: str,
    scope_at: list[int],
    aliases: dict[int, dict[str, TypeAlias]],
) -> list[Binding]:
    bindings: list[Binding] = []
    typed_declaration = re.compile(
        r"\b(?:let|var)\s+[A-Za-z_]\w*\s*:\s*(?P<type>[^=\n;]+?)=\s*$"
    )

    for match in re.finditer(r"\{", masked):
        declarations = list(typed_declaration.finditer(masked[: match.start()]))
        if not declarations:
            continue
        declaration = declarations[-1]
        if masked[declaration.end() : match.start()].strip():
            continue
        type_start, type_end = declaration.span("type")
        declaration_aliases = aliases_for_position(aliases, scope_at, declaration.start())
        type_text = expand_type_aliases(masked[type_start:type_end], declaration_aliases)
        opening = type_text.find("(")
        if opening < 0:
            continue
        closing = matching_parenthesis(type_text, opening)
        if closing is None:
            continue
        parameter_types = [
            type_text[start:end].strip()
            for start, end in split_top_level(type_text, opening + 1, closing, ",")
        ]

        remainder_start = match.end()
        capture_list_start = re.match(r"\s*\[", masked[remainder_start:])
        if capture_list_start is not None:
            opening_capture = remainder_start + capture_list_start.end() - 1
            closing_capture = matching_delimiter(
                masked,
                opening_capture,
                "[",
                "]",
            )
            if closing_capture is None:
                continue
            remainder_start = closing_capture + 1
        remainder = masked[remainder_start:]
        named_parameters = re.match(
            r"\s*(?P<names>[A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s+in\b",
            remainder,
        )
        if named_parameters:
            names = [name.strip() for name in named_parameters.group("names").split(",")]
            if len(parameter_types) != len(names):
                continue
            body_position = remainder_start + named_parameters.end()
        else:
            names = [f"${index}" for index in range(len(parameter_types))]
            body_position = match.end()

        scope = scope_at[min(match.start(), len(scope_at) - 1)]
        for name, parameter_type in zip(names, parameter_types):
            bindings.append(
                Binding(
                    name=name,
                    position=body_position,
                    scope=scope,
                    sensitive=is_sensitive_type(parameter_type, declaration_aliases),
                    logger=is_logger_type(parameter_type, declaration_aliases),
                )
            )
    return bindings


def parameter_bindings(
    masked: str,
    start: int,
    end: int,
    position: int,
    scope: int,
    aliases: dict[str, TypeAlias],
) -> list[Binding]:
    bindings: list[Binding] = []
    for parameter_start, parameter_end in split_top_level(masked, start, end, ","):
        parameter = masked[parameter_start:parameter_end]
        colon_ranges = split_top_level(parameter, 0, len(parameter), ":")
        if len(colon_ranges) < 2:
            continue
        colon = colon_ranges[0][1]
        labels = re.findall(r"[A-Za-z_]\w*", parameter[:colon])
        if not labels:
            continue
        type_text = parameter[colon + 1 :]
        bindings.append(
            Binding(
                name=labels[-1],
                position=position,
                scope=scope,
                sensitive=is_sensitive_type(type_text, aliases),
                logger=is_logger_type(type_text, aliases),
            )
        )
    return bindings


def variable_bindings(
    masked: str,
    scopes: list[Scope],
    scope_at: list[int],
    factories: set[str],
    aliases: dict[int, dict[str, TypeAlias]],
    logger_types: dict[int, set[str]],
) -> list[Binding]:
    bindings: list[Binding] = []
    pattern = re.compile(
        r"\b(?:let|var)\s+(?P<name>[A-Za-z_]\w*)\s*"
        r"(?::\s*(?P<type>[^=\n;{]+?))?\s*"
        r"(?:=\s*(?P<initializer>[^;\n]+))?"
        r"(?=\s*(?:;|\n|$|\{))"
    )
    for match in pattern.finditer(masked):
        name = match.group("name")
        scope = scope_at[min(match.start(), len(scope_at) - 1)] if scope_at else 0
        scope_aliases = aliases.get(scope, {})
        annotation = match.group("type") or ""
        initializer = match.group("initializer")
        is_sensitive = is_sensitive_type(annotation, scope_aliases)
        is_logger = is_logger_type(annotation, scope_aliases)
        if initializer:
            constructor = initializer_constructor(initializer)
            if constructor is not None:
                callee, constructed_type = constructor
                is_sensitive |= is_sensitive_type(constructed_type, scope_aliases)
                is_logger |= (
                    callee == "APKLogger"
                    or callee.endswith(".APKLogger")
                    or callee in factories
                    or callee in logger_types.get(scope, set())
                    or callee.rsplit(".", 1)[-1] in logger_types.get(scope, set())
                )
        bindings.append(
            Binding(
                name=name,
                position=match.start(),
                scope=scope,
                sensitive=is_sensitive,
                logger=is_logger,
                initializer=initializer,
            )
        )
    return bindings


def propagate_binding_aliases(
    masked: str,
    scopes: list[Scope],
    scope_at: list[int],
    bindings: list[Binding],
) -> None:
    changed = True
    while changed:
        changed = False
        for binding in bindings:
            if binding.initializer is None:
                continue
            identifiers = set(re.findall(r"\b[A-Za-z_]\w*\b", binding.initializer))
            for identifier in identifiers:
                source_binding = resolve_binding(
                    identifier,
                    binding.position,
                    scopes,
                    scope_at,
                    bindings,
                )
                if source_binding is not None:
                    if source_binding.sensitive and not binding.sensitive:
                        binding.sensitive = True
                        changed = True
                    if (
                        source_binding.logger
                        and not binding.logger
                        and is_simple_logger_alias(binding.initializer)
                    ):
                        binding.logger = True
                        changed = True


def is_simple_logger_alias(initializer: str) -> bool:
    return re.fullmatch(
        r"\s*(?:(?:try|await|try\?|try!)\s+)*(?:self\s*\.\s*)?"
        r"[A-Za-z_]\w*\s*[?!]?\s*",
        initializer,
    ) is not None


def is_logger_type_alias(type_text: str, aliases: dict[str, TypeAlias]) -> bool:
    expanded = expand_type_aliases(type_text, aliases)
    expanded = re.sub(r"\s*\.\s*", ".", expanded)
    expanded = re.sub(r"\b(?:DiagnosticsCore\.)+(?=APKLogger\b)", "", expanded)
    normalized = re.sub(r"[\s()]", "", expanded)
    return normalized in {"Logger", "Logger?", "os.Logger", "os.Logger?"}


def initializer_constructor(initializer: str) -> tuple[str, str] | None:
    prefix = r"\s*(?:(?:try|await|try\?|try!)\s+)*"
    start = re.match(prefix, initializer)
    cursor = start.end() if start is not None else 0
    name_match = re.match(
        r"[A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*",
        initializer[cursor:],
    )
    if name_match is None:
        return None
    callee = re.sub(r"\s+", "", name_match.group(0))
    type_end = cursor + name_match.end()
    while type_end < len(initializer) and initializer[type_end].isspace():
        type_end += 1
    if type_end < len(initializer) and initializer[type_end] == "<":
        generic_end = matching_angle_bracket(initializer, type_end)
        if generic_end is None:
            return None
        type_end = generic_end + 1
    constructed_type = initializer[cursor:type_end].strip()
    while type_end < len(initializer) and initializer[type_end].isspace():
        type_end += 1
    if initializer.startswith(".init", type_end):
        type_end += len(".init")
        while type_end < len(initializer) and initializer[type_end].isspace():
            type_end += 1
    if type_end >= len(initializer) or initializer[type_end] != "(":
        return None
    return callee, constructed_type


def logger_calls(
    masked: str,
    scopes: list[Scope],
    scope_at: list[int],
    bindings: list[Binding],
    factories: set[str],
    logger_types: dict[int, set[str]],
) -> list[tuple[int, str]]:
    calls: set[tuple[int, str]] = set()
    variable_call = re.compile(
        rf"(?<![\w])([A-Za-z_]\w*)\s*(?:[?!]\s*)?\.\s*"
        rf"({LOGGER_METHOD_PATTERN})\s*\("
    )
    for match in variable_call.finditer(masked):
        binding = resolve_binding(
            match.group(1),
            match.start(),
            scopes,
            scope_at,
            bindings,
        )
        if binding is not None and binding.logger:
            calls.add((masked.find("(", match.start(), match.end()), match.group(1)))

    callees = {"APKLogger", *factories}
    callees.update(name for names in logger_types.values() for name in names)
    for callee in callees:
        call_pattern = re.compile(
            rf"(?<![\w]){re.escape(callee)}(?:\s*\.\s*init)?\s*\("
        )
        for match in call_pattern.finditer(masked):
            scope = scope_at[min(match.start(), len(scope_at) - 1)] if scope_at else 0
            if (
                callee != "APKLogger"
                and callee not in factories
                and callee not in logger_types.get(scope, set())
            ):
                continue
            initializer_open = masked.find("(", match.start(), match.end())
            initializer_close = matching_parenthesis(masked, initializer_open)
            if initializer_close is None:
                continue
            cursor = initializer_close + 1
            while cursor < len(masked) and masked[cursor].isspace():
                cursor += 1
            method = re.match(
                rf"(?:[?!]\s*)?\.\s*({LOGGER_METHOD_PATTERN})\s*\(",
                masked[cursor:],
            )
            if method is not None:
                method_open = cursor + method.end() - 1
                calls.add((method_open, callee))
    return sorted(calls)


def line_number(source: str, position: int) -> int:
    return source.count("\n", 0, position) + 1


def identifier_is_referenced(name: str, source: str) -> bool:
    pattern = re.escape(name) + r"(?!\w)" if name.startswith("$") else rf"\b{re.escape(name)}\b"
    return re.search(pattern, source) is not None


def lint_source(path: str, source: str) -> list[str]:
    findings: list[str] = []
    masked = blank_non_code(source)
    scopes, scope_at = build_scopes(masked)
    alias_declarations = collect_type_aliases(masked, scope_at)
    aliases = aliases_by_scope(alias_declarations, scopes)
    logger_types = {
        scope: {
            name
            for name in scope_aliases
            if is_logger_type(name, scope_aliases)
        }
        for scope, scope_aliases in aliases.items()
    }

    for api, pattern in FORBIDDEN_APIS:
        for match in pattern.finditer(masked):
            findings.append(f"{path}:{line_number(source, match.start())}: forbidden {api}")
    for match in re.finditer(
        r"\btypealias\s+([A-Za-z_]\w*)(?:\s*<[^;\n=]+>)?\s*=",
        masked,
    ):
        alias = match.group(1)
        scope = scope_at[min(match.start(), len(scope_at) - 1)] if scope_at else 0
        if is_logger_type_alias(alias, aliases.get(scope, {})):
            findings.append(
                f"{path}:{line_number(source, match.start())}: forbidden Logger type alias '{alias}'"
            )

    parameter_bindings, factories = function_parameters(masked, scopes, scope_at, aliases)
    bindings = parameter_bindings + variable_bindings(
        masked,
        scopes,
        scope_at,
        factories,
        aliases,
        logger_types,
    )
    propagate_binding_aliases(masked, scopes, scope_at, bindings)

    for opening, receiver in logger_calls(
        masked,
        scopes,
        scope_at,
        bindings,
        factories,
        logger_types,
    ):
        closing = matching_parenthesis(masked, opening)
        if closing is None:
            continue
        message_end = first_argument_end(masked, opening + 1, closing)
        for expression_start, expression_end in string_literal_interpolations(
            source,
            masked,
            opening + 1,
            message_end,
        ):
            expression = source[expression_start:expression_end]
            expression_mask = masked[expression_start:expression_end]
            if not has_privacy_argument(expression_mask):
                findings.append(
                    f"{path}:{line_number(source, expression_start)}: "
                    "APKLogger interpolation is missing a privacy argument"
                )
            for binding in bindings:
                if (
                    binding.sensitive
                    and identifier_is_referenced(binding.name, expression_mask)
                    and resolve_binding(
                        binding.name,
                        expression_start,
                        scopes,
                        scope_at,
                        bindings,
                    )
                    is binding
                ):
                    findings.append(
                        f"{path}:{line_number(source, expression_start)}: "
                        f"Sensitive value '{binding.name}' is used in an APKLogger interpolation"
                    )
                    break

    return findings


def is_exempt(path: str) -> bool:
    normalized = path.replace("\\", "/").removeprefix("./")
    return (
        normalized.startswith("Packages/DiagnosticsCore/")
        or normalized.startswith("scripts/")
        or normalized.startswith("Tests/Fixtures/compile-fail/")
        or normalized == "CLI/apkrun/Support/Output.swift"
    )


def repository_files(root: Path) -> list[Path]:
    result = subprocess.run(
        [
            "git",
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
    )
    names = result.stdout.decode("utf-8").split("\0")
    return [
        root / name
        for name in names
        if name
        and Path(name).suffix in SOURCE_SUFFIXES
        and not is_exempt(name)
        and (root / name).is_file()
    ]


def self_test(root: Path) -> list[str]:
    fixture_root = root / "scripts/tests/fixtures/logging"
    expected = {
        "os-logger.swift": "forbidden os.Logger",
        "logger-init.swift": "forbidden Logger(",
        "print.swift": "forbidden print(",
        "nslog.swift": "forbidden NSLog",
        "os-log.swift": "forbidden os_log",
        "regex-hidden.swift": "forbidden print(",
        "slash-regex-hidden.swift": "forbidden print(",
        "raw-string-escaped-hidden.swift": "forbidden print(",
        "missing-privacy.swift": "missing a privacy argument",
        "sensitive-alias.swift": "Sensitive value",
        "factory-logger.swift": "Sensitive value",
        "local-logger-typealias.swift": "Sensitive value",
        "native-logger-typealias.swift": "forbidden Logger type alias",
        "logger-alias.swift": "Sensitive value",
        "optional-logger.swift": "Sensitive value",
        "closure-sensitive.swift": "Sensitive value",
        "inferred-closure-sensitive.swift": "Sensitive value",
        "sensitive-handler-typealias.swift": "Sensitive value",
        "sensitive-constructor-typealias.swift": "Sensitive value",
        "sensitive-generic-constructor-typealias.swift": "Sensitive value",
        "module-qualified-sensitive.swift": "Sensitive value",
        "implicit-closure-sensitive.swift": "Sensitive value",
        "captured-inferred-closure-sensitive.swift": "Sensitive value",
        "generic-handler-sensitive.swift": "Sensitive value",
        "scoped-typealiases.swift": "Sensitive value",
        "temporary-logger.swift": "missing a privacy argument",
        "scope-sensitive.swift": "Sensitive value",
    }
    errors: list[str] = []
    for filename, expected_text in expected.items():
        path = fixture_root / filename
        if not path.is_file():
            errors.append(f"missing lint fixture: {path}")
            continue
        source = path.read_text(encoding="utf-8")
        findings = lint_source(str(path.relative_to(root)), source)
        matching = [finding for finding in findings if expected_text in finding]
        if not matching:
            errors.append(f"fixture did not trigger '{expected_text}': {filename}")
        if filename == "scope-sensitive.swift":
            public_line = next(
                (
                    number
                    for number, line in enumerate(source.splitlines(), start=1)
                    if 'log.info("public ' in line
                ),
                None,
            )
            if len(matching) != 1 or (
                public_line is not None
                and any(f"{path.relative_to(root)}:{public_line}:" in finding for finding in findings)
            ):
                errors.append("same-name public value was incorrectly treated as Sensitive")
        if filename == "scoped-typealiases.swift":
            public_line = next(
                (
                    number
                    for number, line in enumerate(source.splitlines(), start=1)
                    if 'log.info("public ' in line
                ),
                None,
            )
            if len(matching) != 1 or (
                public_line is not None
                and any(f"{path.relative_to(root)}:{public_line}:" in finding for finding in findings)
            ):
                errors.append("a scoped public type alias was incorrectly treated as Sensitive")
            if not any("forbidden Logger type alias 'ScopedLogger'" in finding for finding in findings):
                errors.append("a scoped NativeLogger alias shadow hid a global Logger alias")

    clean_fixture = fixture_root / "allowed.swift"
    if not clean_fixture.is_file():
        errors.append(f"missing lint fixture: {clean_fixture}")
    elif lint_source(
        str(clean_fixture.relative_to(root)),
        clean_fixture.read_text(encoding="utf-8"),
    ):
        errors.append(f"allowed logging fixture failed: {clean_fixture}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()

    if args.self_test:
        errors = self_test(root)
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        print("check-logging self-test passed")

    findings: list[str] = []
    for path in repository_files(root):
        relative_path = path.relative_to(root).as_posix()
        try:
            source = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        findings.extend(lint_source(relative_path, source))

    if findings:
        print("\n".join(findings), file=sys.stderr)
        return 1
    print("logging checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
