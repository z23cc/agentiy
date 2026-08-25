//! Immutable multi-root catalog composition artifacts for P4-8e.
//!
//! Swift supplies only an ordered descriptor list. `InventoryScope` atomically captures the exact
//! per-root generations, this module validates file/entry alignment and composes outside the scope
//! mutex, and the scope revalidates those captures before registering a handle.

use std::sync::Arc;

use crate::inventory::{
    InventoryFileRecord, InventorySearchCatalogEntry, merge_root_catalog_shard_file_entry_slices,
};

use super::generation::RootGeneration;
use super::ids::{RootId, RootLifetimeId};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ComposedRootDescriptor {
    pub root_id: RootId,
    pub expected_root_lifetime: RootLifetimeId,
    /// `None` is strict: the root must still have no published generation and contributes no rows.
    pub expected_generation: Option<u64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CompositionAccounting {
    NormalPresentation,
    UncachedFallback,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CompositionError {
    MisalignedSource,
    MisalignedOutput,
}

#[derive(Clone, Debug)]
enum ComposedCatalogStorage {
    Empty,
    Reused(Arc<RootGeneration>),
    Owned {
        files: Vec<InventoryFileRecord>,
        entries: Vec<InventorySearchCatalogEntry>,
    },
}

#[derive(Clone, Debug)]
pub struct ComposedCatalogArtifact {
    source_root_ids: Vec<RootId>,
    storage: ComposedCatalogStorage,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ComposedSnapshotPage {
    pub files: Vec<InventoryFileRecord>,
    pub entries: Vec<InventorySearchCatalogEntry>,
}

impl ComposedCatalogArtifact {
    pub(crate) fn compose(
        descriptors: &[ComposedRootDescriptor],
        generations: &[Option<Arc<RootGeneration>>],
    ) -> Result<Self, CompositionError> {
        if descriptors.len() != generations.len() {
            return Err(CompositionError::MisalignedSource);
        }
        for (descriptor, generation) in descriptors.iter().zip(generations) {
            match (descriptor.expected_generation, generation) {
                (None, None) => {}
                (Some(expected), Some(generation))
                    if generation.root_id == descriptor.root_id
                        && generation.root_lifetime == descriptor.expected_root_lifetime
                        && generation.generation == expected
                        && generation.files.len() == generation.entries.len()
                        && aligned(&generation.files, &generation.entries) => {}
                _ => return Err(CompositionError::MisalignedSource),
            }
        }

        let storage = match generations {
            [] => ComposedCatalogStorage::Empty,
            [None] => ComposedCatalogStorage::Empty,
            [Some(generation)] => ComposedCatalogStorage::Reused(Arc::clone(generation)),
            _ => {
                let shards: Vec<_> = generations
                    .iter()
                    .map(|generation| match generation {
                        Some(generation) => {
                            (generation.files.as_slice(), generation.entries.as_slice())
                        }
                        None => (&[][..], &[][..]),
                    })
                    .collect();
                let (files, entries) = merge_root_catalog_shard_file_entry_slices(&shards);
                if files.len() != entries.len() || !aligned(&files, &entries) {
                    return Err(CompositionError::MisalignedOutput);
                }
                ComposedCatalogStorage::Owned { files, entries }
            }
        };
        Ok(Self {
            source_root_ids: descriptors
                .iter()
                .map(|descriptor| descriptor.root_id)
                .collect(),
            storage,
        })
    }

    #[must_use]
    pub fn source_root_ids(&self) -> &[RootId] {
        &self.source_root_ids
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.files().len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    #[must_use]
    pub fn page(&self, offset: usize, limit: usize) -> ComposedSnapshotPage {
        let end = offset.saturating_add(limit).min(self.len());
        if offset >= end {
            return ComposedSnapshotPage::default();
        }
        ComposedSnapshotPage {
            files: self.files()[offset..end].to_vec(),
            entries: self.entries()[offset..end].to_vec(),
        }
    }

    #[must_use]
    pub(crate) fn reused_root_generation(&self) -> Option<(RootId, u64)> {
        match &self.storage {
            ComposedCatalogStorage::Reused(generation) => {
                Some((generation.root_id, generation.generation))
            }
            ComposedCatalogStorage::Empty | ComposedCatalogStorage::Owned { .. } => None,
        }
    }

    fn files(&self) -> &[InventoryFileRecord] {
        match &self.storage {
            ComposedCatalogStorage::Empty => &[],
            ComposedCatalogStorage::Reused(generation) => &generation.files,
            ComposedCatalogStorage::Owned { files, .. } => files,
        }
    }

    fn entries(&self) -> &[InventorySearchCatalogEntry] {
        match &self.storage {
            ComposedCatalogStorage::Empty => &[],
            ComposedCatalogStorage::Reused(generation) => &generation.entries,
            ComposedCatalogStorage::Owned { entries, .. } => entries,
        }
    }
}

fn aligned(files: &[InventoryFileRecord], entries: &[InventorySearchCatalogEntry]) -> bool {
    files.iter().zip(entries).all(|(file, entry)| {
        file.id == entry.id
            && file.root_id == entry.root_id
            && file.name == entry.name
            && file.relative_path == entry.relative_path
            && file.standardized_relative_path == entry.standardized_relative_path
            && file.full_path == entry.full_path
            && file.standardized_full_path == entry.standardized_full_path
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inventory::{InventoryRootRecord, InventorySearchCatalogEntry};
    use crate::inventory_scope::{GenerationToken, RootLifetimeId};

    fn generation(
        root_byte: u8,
        generation_number: u64,
        root_path: &str,
        rows: &[(&str, u8)],
    ) -> Arc<RootGeneration> {
        let root_id = [root_byte; 16];
        let lifetime = RootLifetimeId::from_bytes([root_byte.wrapping_add(10); 16]);
        let root = InventoryRootRecord {
            id: root_id,
            name: format!("Root{root_byte}"),
            standardized_full_path: root_path.to_owned(),
        };
        let files: Vec<_> = rows
            .iter()
            .map(|(relative_path, id_byte)| InventoryFileRecord {
                id: [*id_byte; 16],
                root_id,
                name: (*relative_path).to_owned(),
                relative_path: (*relative_path).to_owned(),
                standardized_relative_path: (*relative_path).to_owned(),
                full_path: format!("{root_path}/{relative_path}"),
                standardized_full_path: format!("{root_path}/{relative_path}"),
                parent_folder_id: None,
                modification_date: None,
            })
            .collect();
        let entries = files
            .iter()
            .map(|file| InventorySearchCatalogEntry::new(file, &root))
            .collect();
        Arc::new(RootGeneration {
            root_id,
            root_lifetime: lifetime,
            generation: generation_number,
            token: GenerationToken::new(lifetime, generation_number),
            files,
            folders: vec![],
            entries,
            path_index: Arc::new(super::super::path_index::RootPathIndex::full(&[])),
        })
    }

    fn descriptor(generation: &RootGeneration) -> ComposedRootDescriptor {
        ComposedRootDescriptor {
            root_id: generation.root_id,
            expected_root_lifetime: generation.root_lifetime,
            expected_generation: Some(generation.generation),
        }
    }

    #[test]
    fn zero_and_never_published_sources_are_empty() {
        let empty = ComposedCatalogArtifact::compose(&[], &[]).expect("empty composition");
        assert!(empty.is_empty());

        let descriptor = ComposedRootDescriptor {
            root_id: [1; 16],
            expected_root_lifetime: RootLifetimeId::from_bytes([2; 16]),
            expected_generation: None,
        };
        let empty = ComposedCatalogArtifact::compose(&[descriptor], &[None])
            .expect("strict unpublished source");
        assert!(empty.is_empty());
        assert_eq!(empty.source_root_ids(), &[[1; 16]]);
    }

    #[test]
    fn one_source_reuses_generation_and_pages_aligned_rows() {
        let generation = generation(1, 7, "/b", &[("b.swift", 2), ("c.swift", 3)]);
        let artifact = ComposedCatalogArtifact::compose(
            &[descriptor(&generation)],
            &[Some(Arc::clone(&generation))],
        )
        .expect("single source");
        assert_eq!(artifact.reused_root_generation(), Some(([1; 16], 7)));
        let page = artifact.page(1, 10);
        assert_eq!(page.files.len(), 1);
        assert_eq!(page.files[0].id, page.entries[0].id);
    }

    #[test]
    fn many_sources_merge_by_full_path_and_keep_rows_aligned() {
        let root_b = generation(2, 1, "/b", &[("a.swift", 4)]);
        let root_a = generation(1, 1, "/a", &[("z.swift", 5), ("same.swift", 6)]);
        let descriptors = [descriptor(&root_b), descriptor(&root_a)];
        let artifact =
            ComposedCatalogArtifact::compose(&descriptors, &[Some(root_b), Some(root_a)])
                .expect("multi-root composition");
        let page = artifact.page(0, 10);
        assert_eq!(
            page.files
                .iter()
                .map(|file| file.standardized_full_path.as_str())
                .collect::<Vec<_>>(),
            vec!["/a/same.swift", "/a/z.swift", "/b/a.swift"]
        );
        assert!(
            page.files
                .iter()
                .zip(&page.entries)
                .all(|(file, entry)| file.id == entry.id)
        );
    }

    #[test]
    fn misaligned_source_fails_closed_for_every_shared_path_shape() {
        let generation = generation(1, 1, "/a", &[("a.swift", 1)]);

        let mut broken_relative = (*generation).clone();
        broken_relative.entries[0].relative_path = "other.swift".to_owned();
        let broken_relative_descriptor = descriptor(&broken_relative);
        assert_eq!(
            ComposedCatalogArtifact::compose(
                &[broken_relative_descriptor],
                &[Some(Arc::new(broken_relative))],
            )
            .unwrap_err(),
            CompositionError::MisalignedSource
        );

        let mut broken_full = (*generation).clone();
        broken_full.entries[0].full_path = "/a/other.swift".to_owned();
        let broken_full_descriptor = descriptor(&broken_full);
        assert_eq!(
            ComposedCatalogArtifact::compose(
                &[broken_full_descriptor],
                &[Some(Arc::new(broken_full))],
            )
            .unwrap_err(),
            CompositionError::MisalignedSource
        );
    }
}
