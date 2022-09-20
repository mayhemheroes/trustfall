#![no_main]
use libfuzzer_sys::fuzz_target;

extern crate trustfall_core;

use async_graphql_parser::{parse_query, parse_schema, types::ServiceDocument};
use lazy_static::lazy_static;
use trustfall_core::{
    frontend::{error::FrontendError, parse_doc},
    graphql_query::error::ParseError,
    schema::Schema,
};

fn get_service_doc() -> ServiceDocument {
    let schema = include_str!("../../src/resources/schemas/numbers.graphql");
    parse_schema(schema).unwrap()
}

lazy_static! {
    static ref SCHEMA: Schema = Schema::new(get_service_doc()).unwrap();
}

fuzz_target!(|query_string: &str| {
    if query_string.match_indices("...").count() <= 3 {
        if let Ok(document) = parse_query(query_string) {
            let result = parse_doc(&SCHEMA, &document);
            if let Err(
                FrontendError::OtherError(..)
                | FrontendError::ParseError(ParseError::OtherError(..)),
            ) = result
            {
                unreachable!()
            }
        }
    }
});
