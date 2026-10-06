package org.springframework.samples.petclinic.owner;

import java.time.LocalDateTime;

import org.springframework.samples.petclinic.model.BaseEntity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import jakarta.persistence.UniqueConstraint;

/** A booked clinic slot. The database uniqueness constraint prevents double booking. */
@Entity
@Table(name = "appointments", uniqueConstraints = @UniqueConstraint(name = "uq_appointments_vet_slot", columnNames = { "vet_id", "starts_at" }))
public class Appointment extends BaseEntity {

	@Column(name = "pet_id", nullable = false)
	private Integer petId;

	@Column(name = "vet_id", nullable = false)
	private Integer vetId;

	@Column(name = "starts_at", nullable = false)
	private LocalDateTime startsAt;

	@Column(name = "description", nullable = false, length = 255)
	private String description;

	protected Appointment() {
	}

	public Appointment(Integer petId, Integer vetId, LocalDateTime startsAt, String description) {
		this.petId = petId;
		this.vetId = vetId;
		this.startsAt = startsAt;
		this.description = description;
	}

	public Integer getPetId() { return petId; }

	public Integer getVetId() { return vetId; }

	public LocalDateTime getStartsAt() { return startsAt; }

	public String getDescription() { return description; }

}
