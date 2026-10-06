package org.springframework.samples.petclinic.owner;

import java.time.DayOfWeek;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.ZoneId;
import java.util.List;
import java.util.Set;
import java.util.stream.IntStream;

import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.samples.petclinic.vet.VetRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class AppointmentService {

	private static final ZoneId CLINIC_ZONE = ZoneId.of("Asia/Seoul");

	private static final List<LocalTime> CLINIC_SLOTS = IntStream.range(9, 17)
		.mapToObj(hour -> LocalTime.of(hour, 0)).toList();

	private final AppointmentRepository appointments;

	private final OwnerRepository owners;

	private final VetRepository vets;

	public AppointmentService(AppointmentRepository appointments, OwnerRepository owners, VetRepository vets) {
		this.appointments = appointments;
		this.owners = owners;
		this.vets = vets;
	}

	@Transactional(readOnly = true)
	public List<LocalTime> availableSlots(Integer vetId, LocalDate date) {
		if (vetId == null || date == null || vets.findById(vetId).isEmpty() || isClosed(date)) {
			return List.of();
		}
		LocalDateTime now = LocalDateTime.now(CLINIC_ZONE);
		Set<LocalTime> booked = appointments
			.findByVetIdAndStartsAtBetween(vetId, date.atStartOfDay(), date.atTime(LocalTime.MAX))
			.stream().map(appointment -> appointment.getStartsAt().toLocalTime())
			.collect(java.util.stream.Collectors.toSet());
		return CLINIC_SLOTS.stream()
			.filter(time -> date.atTime(time).isAfter(now) && !booked.contains(time))
			.toList();
	}

	@Transactional
	public Appointment book(Integer ownerId, Integer petId, AppointmentForm form) {
		Owner owner = owners.findById(ownerId).orElseThrow(() -> new IllegalArgumentException("Owner not found"));
		if (owner.getPet(petId) == null) {
			throw new IllegalArgumentException("Pet does not belong to owner");
		}
		if (form.getVetId() == null || vets.findById(form.getVetId()).isEmpty()) {
			throw new IllegalArgumentException("Veterinarian not found");
		}
		if (form.getDate() == null || form.getTime() == null
				|| !availableSlots(form.getVetId(), form.getDate()).contains(form.getTime())) {
			throw new IllegalArgumentException("Appointment slot is unavailable");
		}
		String description = form.getDescription() == null ? "" : form.getDescription().trim();
		if (description.isEmpty() || description.length() > 255) {
			throw new IllegalArgumentException("Description must be 1 to 255 characters");
		}
		LocalDateTime startsAt = form.getDate().atTime(form.getTime());
		if (appointments.existsByVetIdAndStartsAt(form.getVetId(), startsAt)) {
			throw new IllegalArgumentException("Appointment slot is already booked");
		}
		try {
			return appointments.saveAndFlush(new Appointment(petId, form.getVetId(), startsAt, description));
		}
		catch (DataIntegrityViolationException exception) {
			throw new IllegalArgumentException("Appointment slot is already booked", exception);
		}
	}

	private boolean isClosed(LocalDate date) {
		return date.getDayOfWeek() == DayOfWeek.SATURDAY || date.getDayOfWeek() == DayOfWeek.SUNDAY;
	}

}
