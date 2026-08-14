# ``AutoChartSpecification``

Describe one chart family, its channels, and its safe data preparation.

## Overview

A specification is serializable and stable enough to pass between application
layers. It is not self-validating: channel meaning depends on a particular
``AutoChartTable``. Call
``AutoChartEngine/validate(specification:for:)`` before storing or rendering a
caller-created value, and validate again when the table schema or metadata
changes.

The ``id`` derives deterministically from all specification fields. It identifies
an exact design for deduplication and SwiftUI identity; it isn't a database key.

## Topics

### Design

- ``family``
- ``encoding``
- ``aggregation``
- ``binCount``
- ``orientation``
- ``stacking``
- ``sort``
- ``title``
- ``id``

### Supporting Types

- ``AutoChartEncoding``
- ``AutoChartFamily``
- ``AutoChartAggregation``
- ``AutoChartOrientation``
- ``AutoChartStacking``
- ``AutoChartSort``

### Guides

- <doc:CustomSpecifications>
- <doc:ChartFamilyReference>

