//! Amount parsing and display helpers for SETU raw units.
//!
//! Chain state stores integer raw units. User-facing decimal strings are parsed
//! only at API/CLI boundaries before entering consensus or execution paths.

use thiserror::Error;

pub const SETU_SYMBOL: &str = "SETU";
pub const SETU_COIN_TYPE: &str = "ROOT";
pub const SETU_DECIMALS: u8 = 8;
pub const SETU_UNIT: u64 = 100_000_000;
pub const MAX_SETU_UNITS: u64 = u64::MAX;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum AmountParseError {
    #[error("amount cannot be empty")]
    Empty,
    #[error("amount contains invalid character: {0}")]
    InvalidCharacter(char),
    #[error("amount contains multiple decimal points")]
    MultipleDecimalPoints,
    #[error("amount must include digits before and after decimal point")]
    MissingDigits,
    #[error("amount has too many fractional digits: {actual}, max {max}")]
    TooManyFractionalDigits { actual: usize, max: u8 },
    #[error("decimal scale overflows u64 for decimals={decimals}")]
    DecimalScaleOverflow { decimals: u8 },
    #[error("amount overflows u64 raw units")]
    Overflow,
}

pub fn parse_setu_amount_to_units(input: &str) -> Result<u64, AmountParseError> {
    parse_display_amount_to_units(input, SETU_DECIMALS)
}

pub fn format_setu_units(units: u64) -> String {
    format_units_to_display(units, SETU_DECIMALS)
}

pub fn is_setu_token_identifier(value: &str) -> bool {
    value.eq_ignore_ascii_case("setu") || value.eq_ignore_ascii_case(SETU_COIN_TYPE)
}

pub fn parse_display_amount_to_units(
    input: &str,
    decimals: u8,
) -> Result<u64, AmountParseError> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(AmountParseError::Empty);
    }

    let mut dot_count = 0usize;
    for ch in trimmed.chars() {
        if ch == '.' {
            dot_count += 1;
            if dot_count > 1 {
                return Err(AmountParseError::MultipleDecimalPoints);
            }
        } else if !ch.is_ascii_digit() {
            return Err(AmountParseError::InvalidCharacter(ch));
        }
    }

    let scale = decimal_scale(decimals)?;
    let (whole_part, fractional_part) = match trimmed.split_once('.') {
        Some((whole, fractional)) => {
            if whole.is_empty() || fractional.is_empty() {
                return Err(AmountParseError::MissingDigits);
            }
            if fractional.len() > decimals as usize {
                return Err(AmountParseError::TooManyFractionalDigits {
                    actual: fractional.len(),
                    max: decimals,
                });
            }
            (whole, fractional)
        }
        None => (trimmed, ""),
    };

    if whole_part.is_empty() || !whole_part.bytes().all(|b| b.is_ascii_digit()) {
        return Err(AmountParseError::MissingDigits);
    }

    let whole_units = parse_digits_u128(whole_part)?
        .checked_mul(scale as u128)
        .ok_or(AmountParseError::Overflow)?;

    let fractional_units = if fractional_part.is_empty() {
        0u128
    } else {
        let fractional_value = parse_digits_u128(fractional_part)?;
        let missing_places = decimals as usize - fractional_part.len();
        let fractional_scale = decimal_scale(missing_places as u8)? as u128;
        fractional_value
            .checked_mul(fractional_scale)
            .ok_or(AmountParseError::Overflow)?
    };

    let units = whole_units
        .checked_add(fractional_units)
        .ok_or(AmountParseError::Overflow)?;
    u64::try_from(units).map_err(|_| AmountParseError::Overflow)
}

pub fn format_units_to_display(units: u64, decimals: u8) -> String {
    let scale = match decimal_scale(decimals) {
        Ok(scale) => scale,
        Err(_) => return units.to_string(),
    };

    if decimals == 0 {
        return units.to_string();
    }

    let whole = units / scale;
    let fractional = units % scale;
    if fractional == 0 {
        return whole.to_string();
    }

    let mut fractional_str = format!("{:0width$}", fractional, width = decimals as usize);
    while fractional_str.ends_with('0') {
        fractional_str.pop();
    }
    format!("{}.{}", whole, fractional_str)
}

fn decimal_scale(decimals: u8) -> Result<u64, AmountParseError> {
    let mut scale = 1u64;
    for _ in 0..decimals {
        scale = scale
            .checked_mul(10)
            .ok_or(AmountParseError::DecimalScaleOverflow { decimals })?;
    }
    Ok(scale)
}

fn parse_digits_u128(input: &str) -> Result<u128, AmountParseError> {
    let mut value = 0u128;
    for byte in input.bytes() {
        if !byte.is_ascii_digit() {
            return Err(AmountParseError::InvalidCharacter(byte as char));
        }
        value = value
            .checked_mul(10)
            .and_then(|v| v.checked_add((byte - b'0') as u128))
            .ok_or(AmountParseError::Overflow)?;
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_setu_whole_amount() {
        assert_eq!(parse_setu_amount_to_units("1"), Ok(100_000_000));
    }

    #[test]
    fn parse_setu_decimal_amount() {
        assert_eq!(parse_setu_amount_to_units("1.23"), Ok(123_000_000));
    }

    #[test]
    fn parse_setu_minimum_unit() {
        assert_eq!(parse_setu_amount_to_units("0.00000001"), Ok(1));
    }

    #[test]
    fn parse_padded_display_amount() {
        assert_eq!(parse_setu_amount_to_units("0001.2300"), Ok(123_000_000));
    }

    #[test]
    fn reject_too_many_fractional_digits() {
        assert_eq!(
            parse_setu_amount_to_units("0.000000001"),
            Err(AmountParseError::TooManyFractionalDigits { actual: 9, max: 8 })
        );
    }

    #[test]
    fn reject_malformed_amounts() {
        assert_eq!(parse_setu_amount_to_units("1."), Err(AmountParseError::MissingDigits));
        assert_eq!(parse_setu_amount_to_units(".1"), Err(AmountParseError::MissingDigits));
        assert_eq!(parse_setu_amount_to_units("1e8"), Err(AmountParseError::InvalidCharacter('e')));
        assert_eq!(parse_setu_amount_to_units("-1"), Err(AmountParseError::InvalidCharacter('-')));
    }

    #[test]
    fn reject_overflow_amount() {
        assert_eq!(
            parse_setu_amount_to_units("184467440738"),
            Err(AmountParseError::Overflow)
        );
    }

    #[test]
    fn format_setu_decimal_amount() {
        assert_eq!(format_setu_units(123_000_000), "1.23");
    }

    #[test]
    fn format_setu_whole_amount() {
        assert_eq!(format_setu_units(100_000_000), "1");
    }

    #[test]
    fn format_setu_minimum_unit() {
        assert_eq!(format_setu_units(1), "0.00000001");
    }

    #[test]
    fn identify_setu_aliases() {
        for alias in ["setu", "SETU", "root", "ROOT"] {
            assert!(is_setu_token_identifier(alias));
        }
        assert!(!is_setu_token_identifier("GAME"));
    }
}
