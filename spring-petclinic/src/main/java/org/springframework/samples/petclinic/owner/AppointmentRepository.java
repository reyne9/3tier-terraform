package org.springframework.samples.petclinic.owner;

import java.time.LocalDateTime;
import java.util.List;

import org.springframework.data.jpa.repository.JpaRepository;

public interface AppointmentRepository extends JpaRepository<Appointment, Integer> {

	List<Appointment> findByVetIdAndStartsAtBetween(Integer vetId, LocalDateTime start, LocalDateTime end);

	boolean existsByVetIdAndStartsAt(Integer vetId, LocalDateTime startsAt);

}
